defmodule VoiceLab.Router do
  use Plug.Router
  alias VoiceLab.PolicyParams
  plug :match
  plug :dispatch
  get "/signaling" do
    conn = fetch_query_params(conn)
    if same_origin?(conn) do
      WebSockAdapter.upgrade(conn, VoiceLab.CallSocket, [room: conn.query_params["room"], codec: conn.query_params["codec"]], timeout: 120_000, max_frame_size: 65_536, max_fragmented_message_size: 65_536)
    else send_resp(conn, 403, "cross-origin signaling is not allowed") end
  end
  get "/call" do send_static(conn, "call.html", "text/html; charset=utf-8") end
  get "/call.js" do send_static(conn, "call.js", "text/javascript; charset=utf-8") end
  get "/style.css" do send_static(conn, "style.css", "text/css; charset=utf-8") end
  get "/call.css" do send_static(conn, "call.css", "text/css; charset=utf-8") end
  get "/instrument.js" do send_static(conn, "instrument.js", "text/javascript; charset=utf-8") end
  get "/capture-worklet.js" do send_static(conn, "capture-worklet.js", "text/javascript; charset=utf-8") end
  get "/playback-worklet.js" do send_static(conn, "playback-worklet.js", "text/javascript; charset=utf-8") end
  get "/packet.js" do send_static(conn, "packet.js", "text/javascript; charset=utf-8") end
  get "/jitter-buffer.js" do send_static(conn, "jitter-buffer.js", "text/javascript; charset=utf-8") end
  get "/mulaw.js" do send_static(conn, "mulaw.js", "text/javascript; charset=utf-8") end
  get "/downsample.js" do send_static(conn, "downsample.js", "text/javascript; charset=utf-8") end
  get "/upsample.js" do send_static(conn, "upsample.js", "text/javascript; charset=utf-8") end
  get "/concealment.js" do send_static(conn, "concealment.js", "text/javascript; charset=utf-8") end
  get "/talk-a-indonesian.wav" do send_static(conn, "talk-a-indonesian.wav", "audio/wav") end
  get "/health" do send_resp(conn, 200, "ok") end
  get "/socket" do
    conn = fetch_query_params(conn)
    case PolicyParams.parse(conn.query_params) do
      {:ok, policy} -> WebSockAdapter.upgrade(conn, VoiceLab.Socket, [policy: policy], timeout: 120_000, max_frame_size: 1_024)
      {:error, message} -> send_resp(conn, 400, message)
    end
  end
  get "/" do send_static(conn, "index.html", "text/html; charset=utf-8") end
  get "/app.js" do send_static(conn, "app.js", "text/javascript; charset=utf-8") end
  match _ do send_resp(conn, 404, "not found") end
  defp send_static(conn, filename, content_type), do: conn |> put_resp_content_type(content_type) |> send_file(200, Application.app_dir(:voice_lab, Path.join("priv/static", filename)))
  defp same_origin?(conn) do
    expected = case System.get_env("CALL_PUBLIC_ORIGIN") do nil -> {Atom.to_string(conn.scheme), String.downcase(conn.host), conn.port}; configured -> origin_tuple(configured) end
    case Plug.Conn.get_req_header(conn, "origin") do [] -> true; [origin] -> expected != nil and origin_tuple(origin) == expected; _ -> false end
  end
  defp origin_tuple(value) do
    uri = URI.parse(value)
    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.path in [nil, "", "/"] and uri.query == nil and uri.fragment == nil and uri.userinfo == nil, do: {String.downcase(uri.scheme), String.downcase(uri.host), uri.port || if(uri.scheme == "https", do: 443, else: 80)}, else: nil
  end
end
