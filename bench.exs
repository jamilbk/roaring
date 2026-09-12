Code.require_file("roaring.exs", __DIR__)

defmodule RoaringBench do
  alias PureRoaring, as: R
  import Bitwise
  @range_size 1 <<< 21
  @sample_size 10_000

  def run do
    rounds = env("ROUNDS", 60)
    corpus_size = env("CORPUS", 20)
    repeats = env("REPEATS", 5)
    :rand.seed(:exsss, {101, 2021, 1111})
    IO.puts("Pure Elixir Roaring PoC — no dependencies or NIFs")

    IO.puts(
      "Elixir #{System.version()}, OTP #{System.otp_release()}, #{:erlang.system_info(:system_architecture)}"
    )

    IO.puts(
      "#{rounds} rounds; #{corpus_size} seeded samples/range; #{repeats} corpus repetitions/round"
    )

    IO.puts("Times are microseconds per operation; p95 is of batch means, not request latency.\n")

    ranges = [
      {"100.64.0.0/11", "100.64.0.0", 32, 11},
      {"fd00:2021:1111::/107", "fd00:2021:1111::", 128, 107}
    ]

    datasets =
      Enum.map(ranges, fn {cidr, base, bits, prefix} ->
        true = 1 <<< (bits - prefix) == @range_size
        {:ok, address} = :inet.parse_address(String.to_charlist(base))
        width = if bits == 32, do: 8, else: 16

        base_int =
          address |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< width) + part end)

        true = rem(base_int, @range_size) == 0
        data = Enum.map(1..corpus_size, fn _ -> sample() end)
        # Demonstrate offset conversion for both address families, outside timing.
        Enum.each(data, fn d ->
          Enum.each(d.random, fn offset ->
            ip = base_int + offset
            true = ip - base_int == offset and offset < @range_size
          end)
        end)

        IO.puts(
          "#{cidr}: #{@range_size} addresses; #{@sample_size} unique offsets; #{map_size(hd(data).old.containers)} containers"
        )

        {cidr, data}
      end)

    jobs = [
      {"build / random", fn d -> R.from_list(d.random) end},
      {"build / sorted (general API)", fn d -> R.from_list(d.sorted) end},
      {"build / sorted (sorted API)", fn d -> R.from_sorted_list(d.sorted) end},
      {"sort only", fn d -> Enum.sort(d.random) end},
      {"sort + sorted build", fn d -> R.from_sorted_list(Enum.sort(d.random)) end},
      {"insert one absent offset", fn d -> R.insert(d.old, d.add) end},
      {"remove one present offset", fn d -> R.remove(d.old, d.remove) end},
      {"apply known remove + add", fn d -> d.old |> R.remove(d.remove) |> R.insert(d.add) end},
      {"diff existing old/new (both ways)", fn d -> diff(d.old, d.new) end},
      {"rebuild random new + diff", fn d -> diff(d.old, R.from_list(d.next_random)) end}
    ]

    rows =
      Enum.flat_map(datasets, fn {cidr, data} ->
        IO.puts("\n#{cidr}")
        measure(jobs, data, rounds, repeats, cidr)
      end)

    paired = Enum.zip(elem(Enum.at(datasets, 0), 1), elem(Enum.at(datasets, 1), 1))
    pair_jobs = Enum.map(jobs, fn {name, fun} -> {name, fn {a, b} -> {fun.(a), fun.(b)} end} end)
    IO.puts("\nBoth ranges together (one operation handles 20k offsets)")
    rows = rows ++ measure(pair_jobs, paired, rounds, repeats, "both")
    path = Path.join(__DIR__, "results.csv")

    File.write!(
      path,
      "range,operation,median_us,p95_batch_us,min_us\n" <> Enum.join(rows, "\n") <> "\n"
    )

    IO.puts("\nSaved #{path}")
  end

  defp sample do
    set = unique(MapSet.new())
    random = set |> MapSet.to_list() |> Enum.shuffle()
    sorted = Enum.sort(random)
    remove = hd(random)
    add = absent(set)
    old = R.from_list(random)
    next_random = [add | tl(random)]
    new = R.from_list(next_random)
    true = R.to_list(old) == sorted
    true = R.from_sorted_list(sorted) == old
    true = R.size(old) == @sample_size
    true = old |> R.remove(remove) |> R.insert(add) == new
    true = R.to_list(R.difference(new, old)) == [add]
    true = R.to_list(R.difference(old, new)) == [remove]

    %{
      random: random,
      sorted: sorted,
      old: old,
      new: new,
      next_random: next_random,
      add: add,
      remove: remove
    }
  end

  defp unique(set) do
    if MapSet.size(set) == @sample_size,
      do: set,
      else: unique(MapSet.put(set, :rand.uniform(@range_size) - 1))
  end

  defp absent(set) do
    n = :rand.uniform(@range_size) - 1
    if MapSet.member?(set, n), do: absent(set), else: n
  end

  defp diff(old, new), do: {R.difference(new, old), R.difference(old, new)}

  defp env(name, default) do
    n = String.to_integer(System.get_env(name, Integer.to_string(default)))
    if n < 1, do: raise(ArgumentError, "#{name} must be positive")
    n
  end

  defp measure(jobs, data, rounds, repeats, label) do
    inputs = List.duplicate(data, repeats) |> List.flatten()
    # Warm each scenario, then shuffle scenario order per round to reduce drift.
    Enum.each(jobs, fn {_, fun} -> Enum.each(inputs, fun) end)

    samples =
      Enum.reduce(1..rounds, %{}, fn _, acc ->
        Enum.reduce(Enum.shuffle(jobs), acc, fn {name, fun}, acc ->
          us = time_batch(fun, inputs)
          Map.update(acc, name, [us], &[us | &1])
        end)
      end)

    IO.puts(String.pad_trailing("operation", 37) <> " median µs   p95 batch µs      min µs")

    Enum.map(jobs, fn {name, _} ->
      sorted = Enum.sort(Map.fetch!(samples, name))
      median = percentile(sorted, 0.5)
      p95 = percentile(sorted, 0.95)
      min = hd(sorted)

      IO.puts(
        String.pad_trailing(name, 37) <>
          Enum.map_join([median, p95, min], "", &String.pad_leading(fmt(&1), 13))
      )

      Enum.join([label, name, fmt(median), fmt(p95), fmt(min)], ",")
    end)
  end

  # Fresh worker per batch avoids inheriting the previous scenario's heap size.
  # Process startup, input copying, and initial collection are outside timing.
  defp time_batch(fun, inputs) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        :erlang.garbage_collect()
        start = System.monotonic_time()
        Enum.each(inputs, fun)
        ns = System.convert_time_unit(System.monotonic_time() - start, :native, :nanosecond)
        send(parent, {:measurement, self(), ns / length(inputs) / 1000})
      end)

    receive do
      {:measurement, ^pid, us} ->
        Process.demonitor(ref, [:flush])
        us

      {:DOWN, ^ref, :process, ^pid, reason} ->
        raise "benchmark worker failed: #{inspect(reason)}"
    end
  end

  defp percentile(xs, p), do: Enum.at(xs, max(ceil(length(xs) * p) - 1, 0))
  defp fmt(n), do: :erlang.float_to_binary(n, decimals: 3)
end

RoaringBench.run()
