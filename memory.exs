Code.require_file("roaring.exs", __DIR__)

defmodule RoaringMemory do
  alias PureRoaring, as: R

  def run do
    :rand.seed(:exsss, {101, 2021, 1111})
    pair = {sample(), sample()}
    word_bytes = :erlang.system_info(:wordsize)
    IO.puts("Elixir #{System.version()}, OTP #{System.otp_release()}, word bytes #{word_bytes}")

    for {name, bitmaps} <- [
          {"IPv4", [elem(pair, 0)]},
          {"IPv6", [elem(pair, 1)]},
          {"Both", Tuple.to_list(pair)}
        ] do
      term = if length(bitmaps) == 1, do: hd(bitmaps), else: pair
      bins = for b <- bitmaps, {_, {:array, bin}} <- b.containers, do: bin
      payload = Enum.sum(Enum.map(bins, &byte_size/1))
      referenced = Enum.sum(Enum.map(bins, &:binary.referenced_byte_size/1))

      IO.inspect(
        %{
          offsets: Enum.sum(Enum.map(bitmaps, &R.size/1)),
          containers: length(bins),
          array_payload_bytes: payload,
          referenced_binary_bytes: referenced,
          beam_heap_words: :erts_debug.size(term),
          beam_heap_bytes: :erts_debug.size(term) * word_bytes,
          heap_plus_binary_bytes: :erts_debug.size(term) * word_bytes + referenced,
          etf_bytes: byte_size(:erlang.term_to_binary(term))
        },
        label: name
      )
    end

    # Measure one isolated owner as an additional process-level view. Input
    # sampling lists are in a separate stack frame and collected before reporting.
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        pair = {sample(), sample()}
        :erlang.garbage_collect()

        send(
          parent,
          {:memory, self(),
           Process.info(self(), [:memory, :heap_size, :total_heap_size, :binary])}
        )

        receive do
          :finish -> send(parent, {:cardinality, R.size(elem(pair, 0)) + R.size(elem(pair, 1))})
        end
      end)

    receive do
      {:memory, ^pid, info} ->
        bins = Keyword.fetch!(info, :binary)
        IO.inspect(Keyword.drop(info, [:binary]), label: "Isolated owner after GC")

        IO.inspect(
          %{
            binary_count: length(bins),
            referenced_binary_bytes: Enum.sum(Enum.map(bins, &elem(&1, 1)))
          }, label: "Owner off-heap binaries")

        send(pid, :finish)

      {:DOWN, ^ref, :process, ^pid, reason} ->
        raise inspect(reason)
    end

    receive do
      {:cardinality, 20_000} -> :ok
    end
  end

  defp sample do
    unique(MapSet.new()) |> MapSet.to_list() |> R.from_list()
  end

  defp unique(set) do
    if MapSet.size(set) == 10_000,
      do: set,
      else: unique(MapSet.put(set, :rand.uniform(2_097_152) - 1))
  end
end

RoaringMemory.run()
