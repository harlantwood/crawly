defmodule Crawly.Worker do
  @moduledoc """
  A worker process responsible for the actual work (fetching requests,
  processing responces)
  """
  use GenServer

  require Logger

  # define the default worker fetch interval.
  @default_backoff 300

  defstruct backoff: @default_backoff, spider_name: nil

  def start_link([spider_name]) do
    GenServer.start_link(__MODULE__, [spider_name])
  end

  def init([spider_name]) do
    Crawly.Utils.send_after(self(), :work, @default_backoff)

    {:ok, %Crawly.Worker{spider_name: spider_name, backoff: @default_backoff}}
  end

  def handle_info(:work, state) do
    new_backoff = do_work(state.spider_name, state.backoff)
    Crawly.Utils.send_after(self(), :work, new_backoff)
    {:noreply, %{state | backoff: new_backoff}}
  end

  defp do_work(spider_name, backoff) do
    # Get a request from requests storage.
    case Crawly.RequestsStorage.pop(spider_name) do
      nil ->
        # Slow down a bit when there are no new URLs
        backoff * 2

      request ->
        # Process the request using following group of functions
        functions = [
          {:get_response, &get_response/1},
          {:parse_item, &parse_item/1},
          {:process_parsed_item, &process_parsed_item/1}
        ]

        case :epipe.run(functions, {request, spider_name}) do
          {:error, _step, reason, _step_state} ->
            Logger.error(
              fn ->
                "Crawly worker could not process the request to #{inspect(request.url)}
                  reason: #{inspect(reason)}"
              end)
            @default_backoff
          {:ok, _result} ->
            @default_backoff
        end
    end
  end

  @spec get_response({request, spider_name}) :: result
        when request: Crawly.Request.t(),
             spider_name: atom(),
             response: HTTPoison.Response.t(),
             result: {:ok, response, spider_name} | {:error, term()}
  defp get_response({request, spider_name}) do
    case HTTPoison.get(request.url, request.headers, request.options) do
      {:ok, %HTTPoison.Response{status_code: 200} = response} ->
        {:ok, {response, spider_name}}

      non_successful_response ->
        :ok = maybe_retry_request(spider_name, request)
        {:error, non_successful_response}
    end
  end

  @spec parse_item({response, spider_name}) :: result
        when response: HTTPoison.Response.t(),
             spider_name: atom(),
             response: HTTPoison.Response.t(),
             parsed_item: Crawly.ParsedItem.t(),
             next: {parsed_item, response, spider_name},
             result: {:ok, next} | {:error, term()}
  defp parse_item({response, spider_name}) do
    try do
      parsed_item = spider_name.parse_item(response)
      {:ok, {parsed_item, response, spider_name}}
    catch
      error, reason ->
        stacktrace = :erlang.get_stacktrace()

        Logger.error(
          "Could not parse item, error: #{inspect(error)}, reason: #{
            inspect(reason)
          }, stacktrace: #{inspect(stacktrace)}
          "
        )

        {:error, reason}
    end
  end

  @spec process_parsed_item({parsed_item, response, spider_name}) :: result
        when spider_name: atom(),
             response: HTTPoison.Response.t(),
             parsed_item: Crawly.ParsedItem.t(),
             result: {:ok, :done}
  defp process_parsed_item({parsed_item, response, spider_name}) do
    requests = Map.get(parsed_item, :requests, [])
    items = Map.get(parsed_item, :items, [])

    # Reading HTTP client options
    options = [Application.get_env(:crawly, :follow_redirect, false)]

    options =
      case Application.get_env(:crawly, :proxy, false) do
        false ->
          options

        proxy ->
          options ++ [{:proxy, proxy}]
      end

    # Process all requests one by one
    Enum.each(
      requests,
      fn request ->
        request =
          request
          |> Map.put(:prev_response, response)
          |> Map.put(:options, options)

        Crawly.RequestsStorage.store(spider_name, request)
      end
    )

    # Process all items one by one
    Enum.each(
      items,
      fn item ->
        Crawly.DataStorage.store(spider_name, item)
      end
    )

    {:ok, :done}
  end

  ## Retry a request if max retries allows to do so
  defp maybe_retry_request(spider, %Crawly.Request{retries: retries} = request) do
    max_retires = Application.get_env(:crawly, :max_retries, 3)

    case retries <= max_retires do
      true ->
        Logger.info("Request to #{request.url}, is scheduled for retry")
        :ok = Crawly.RequestsStorage.store(
          spider,
          %Crawly.Request{request | retries: retries + 1}
        )
      false ->
        Logger.info("Dropping request to #{request.url}, (max retries)")
        :ok
    end
  end
end
