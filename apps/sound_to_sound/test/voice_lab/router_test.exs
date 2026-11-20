defmodule VoiceLab.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  alias VoiceLab.Router

  test "health responds ok" do
    conn = Router.call(conn(:get, "/health"), Router.init([]))
    assert {conn.status, conn.resp_body} == {200, "ok"}
  end

  test "every static route has a file" do
    for path <- ~w(/ /app.js /call /call.js /style.css /call.css /instrument.js /capture-worklet.js /playback-worklet.js /packet.js /jitter-buffer.js /mulaw.js /downsample.js /upsample.js /concealment.js /talk-a-indonesian.wav) do
      assert Router.call(conn(:get, path), Router.init([])).status == 200, path
    end
  end
end
