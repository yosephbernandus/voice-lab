defmodule VoiceLab.Sequence do
  @mod 65_536
  def next(n), do: rem(n + 1, @mod)
  def distance(a, b), do: rem(b - a + @mod, @mod)
  def precedes?(a, b), do: distance(a, b) > 0 and distance(a, b) < div(@mod, 2)
end
