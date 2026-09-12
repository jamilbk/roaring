Code.require_file("roaring.exs", __DIR__)

defmodule SingleDiffBench do
  alias PureRoaring, as: R

  def run do
    :rand.seed(:exsss, {101, 2021, 1111})
    IO.puts("Single-element diffs, pure Elixir, 10k unique offsets in 2^21")
    IO.puts("30 rounds x 100 operations; median/p95 of batch means in microseconds")

    for label <- ["IPv4", "IPv6"] do
      corpus =
        for _ <- 1..20 do
          values = unique(MapSet.new()) |> MapSet.to_list() |> Enum.shuffle()
          old = R.from_list(values)
          remove = hd(values)
          # Use a random absent member, rather than preferentially editing container zero.
          add = absent(old)
          inserted = R.insert(old, add)
          removed = R.remove(old, remove)
          add_diff = diff(old, inserted)
          remove_diff = diff(old, removed)
          true = R.to_list(elem(add_diff, 0)) == [add]
          true = R.size(elem(add_diff, 1)) == 0
          true = R.size(elem(remove_diff, 0)) == 0
          true = R.to_list(elem(remove_diff, 1)) == [remove]
          %{old: old, inserted: inserted, removed: removed, add: add, remove: remove}
        end

      IO.puts("\n#{label}")

      jobs = [
        {"diff after one add (snapshots prebuilt)", fn d -> diff(d.old, d.inserted) end},
        {"diff after one remove (snapshots prebuilt)", fn d -> diff(d.old, d.removed) end},
        {"one add + compute diff", fn d -> diff(d.old, R.insert(d.old, d.add)) end},
        {"one remove + compute diff", fn d -> diff(d.old, R.remove(d.old, d.remove)) end}
      ]

      Enum.each(jobs, fn {_, fun} -> Enum.each(corpus, fun) end)

      samples =
        Enum.reduce(1..30, %{}, fn _, acc ->
          Enum.reduce(Enum.shuffle(jobs), acc, fn {name, fun}, acc ->
            us = time_batch(corpus, fun)
            Map.update(acc, name, [us], &[us | &1])
          end)
        end)

      for {name, _} <- jobs do
        values = Enum.sort(samples[name])

        IO.puts(
          "#{name}: median #{fmt(Enum.at(values, 14))} us, p95 #{fmt(Enum.at(values, 28))} us"
        )
      end

      first = hd(corpus)

      for {name, result} <- [
            {"add", diff(first.old, first.inserted)},
            {"remove", diff(first.old, first.removed)}
          ] do
        {added, removed} = result

        IO.puts(
          "#{name} diff: added=#{R.size(added)}, removed=#{R.size(removed)}, array payload=#{payload(added) + payload(removed)} bytes, ETF tuple=#{byte_size(:erlang.term_to_binary(result))} bytes, flat BEAM heap=#{:erts_debug.flat_size(result) * :erlang.system_info(:wordsize)} bytes"
        )
      end
    end
  end

  defp unique(set) do
    if MapSet.size(set) == 10_000,
      do: set,
      else: unique(MapSet.put(set, :rand.uniform(2_097_152) - 1))
  end

  defp absent(old) do
    n = :rand.uniform(2_097_152) - 1
    if R.contains?(old, n), do: absent(old), else: n
  end

  defp diff(old, new), do: {R.difference(new, old), R.difference(old, new)}

  defp payload(bitmap),
    do: Enum.reduce(bitmap.containers, 0, fn {_, {:array, bin}}, acc -> acc + byte_size(bin) end)

  defp fmt(n), do: :erlang.float_to_binary(n, decimals: 3)

  defp time_batch(corpus, fun) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        :erlang.garbage_collect()
        start = System.monotonic_time()
        for _ <- 1..5, do: Enum.each(corpus, fun)
        ns = System.convert_time_unit(System.monotonic_time() - start, :native, :nanosecond)
        send(parent, {:result, self(), ns / 100 / 1000})
      end)

    receive do
      {:result, ^pid, us} ->
        Process.demonitor(ref, [:flush])
        us

      {:DOWN, ^ref, :process, ^pid, reason} ->
        raise inspect(reason)
    end
  end
end

SingleDiffBench.run()
