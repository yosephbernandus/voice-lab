defmodule VoiceLab.CallIce do
  @moduledoc """
  ICE server list handed to each call peer.

  Without TURN credentials the peer gets a public STUN server and `relayConfigured` is
  false. With credentials, short-lived TURN servers come from Cloudflare, and the answer is
  only trusted if every entry is well formed and at least one entry can relay.
  """

  @stun_only [%{"urls" => ["stun:stun.cloudflare.com:3478"]}]
  @url_schemes ["stun:", "turn:", "turns:"]
  @relay_schemes ["turn:", "turns:"]
  @bad_config "TURN configuration is incomplete or invalid"

  def servers do
    case {System.get_env("TURN_KEY_ID"), System.get_env("TURN_API_TOKEN")} do
      {nil, nil} ->
        {:ok, @stun_only, false}

      {key, token} when is_binary(key) and is_binary(token) and token != "" ->
        if key =~ ~r/\A[A-Za-z0-9_-]{1,128}\z/, do: relay_servers(key, token), else: {:error, @bad_config}

      _ ->
        {:error, @bad_config}
    end
  end

  @doc "Check the `iceServers` value a provider returned; `{:ok, list}` only if it can relay."
  def accept_provider_servers(value) do
    servers = List.wrap(value)

    if servers != [] and Enum.all?(servers, &sound?/1) and Enum.any?(servers, &(relay_urls(&1) != [])),
      do: {:ok, servers},
      else: :error
  end

  defp relay_servers(key, token) do
    with {:ok, body} <- request_credentials(key, token),
         {:ok, %{"iceServers" => listed}} <- Jason.decode(body),
         {:ok, servers} <- accept_provider_servers(listed) do
      {:ok, servers, true}
    else
      :unreachable -> {:error, "TURN credential provider failed"}
      _ -> {:error, "TURN provider returned invalid ICE servers"}
    end
  end

  defp request_credentials(key, token) do
    url = ~c"https://rtc.live.cloudflare.com/v1/turn/keys/#{key}/credentials/generate-ice-servers"
    headers = [{~c"authorization", ~c"Bearer #{token}"}, {~c"content-type", ~c"application/json"}]
    http_options = [timeout: 5_000, connect_timeout: 3_000, autoredirect: false, ssl: :httpc.ssl_verify_host_options(true)]

    case :httpc.request(:post, {url, headers, ~c"application/json", ~c"{\"ttl\":3600}"}, http_options, body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      _ -> :unreachable
    end
  end

  defp sound?(%{"urls" => urls} = server) do
    urls = List.wrap(urls)

    urls != [] and Enum.all?(urls, &(is_binary(&1) and String.starts_with?(&1, @url_schemes))) and
      (relay_urls(server) == [] or (filled?(server["username"]) and filled?(server["credential"])))
  end

  defp sound?(_other), do: false

  defp relay_urls(%{"urls" => urls}),
    do: Enum.filter(List.wrap(urls), &String.starts_with?(&1, @relay_schemes))

  defp filled?(value), do: is_binary(value) and value != ""
end
