Code.require_file("roaring.exs", __DIR__)

defmodule ScaleBench do
  alias PureRoaring, as: R
  @universe 2_097_152

  def run do
    sizes =
      System.get_env("SIZES", "100000,1000000")
      |> String.split(",")
      |> Enum.map(&String.to_integer/1)

    rounds = String.to_integer(System.get_env("ROUNDS", "5"))
    corpus = String.to_integer(System.get_env("CORPUS", "2"))
    true = rounds > 0 and corpus > 0

    for size <- sizes do
      true = size > 0 and size < @universe
      :rand.seed(:exsss, {101, 2021, 1111})
      prefix = Path.join(__DIR__, "scale_#{size}")

      IO.puts(
        "\nSIZE #{size} PER STACK | Elixir #{System.version()} OTP #{System.otp_release()} #{:erlang.system_info(:system_architecture)}"
      )

      IO.puts(
        "#{rounds} shuffled rounds, #{corpus} distinct samples/stack; medians of batch-average microseconds"
      )

      data =
        for label <- ["IPv4", "IPv6"] do
          samples = for _ <- 1..corpus, do: sample(size)
          IO.puts("#{label} samples prepared and correctness checked")
          {label, samples}
        end

      pair = {hd(elem(hd(data), 1)).old, hd(elem(List.last(data), 1)).old}

      memory_rows =
        for {label, value} <- [{"IPv4", elem(pair, 0)}, {"IPv6", elem(pair, 1)}, {"both", pair}] do
          m = memory(value)
          IO.puts("MEMORY #{label}: #{inspect(m)}")
          {label, m}
        end

      d = hd(elem(hd(data), 1))

      delta_rows =
        for {name, value} <- [
              {"add_only", diff(d.old, d.inserted)},
              {"remove_only", diff(d.old, d.removed)},
              {"remove_and_add", diff(d.old, d.new)}
            ] do
          m = memory(value)
          IO.puts("DIFF SIZE #{name}: #{inspect(m)}")
          {name, m}
        end

      File.write!(
        prefix <> "_sizes.txt",
        inspect(%{full: memory_rows, diff: delta_rows}, pretty: true, limit: :infinity) <> "\n"
      )

      groups = data ++ [{"both", Enum.zip(elem(hd(data), 1), elem(List.last(data), 1))}]

      rows =
        Enum.flat_map(groups, fn {label, inputs} ->
          jobs = jobs()

          jobs =
            if label == "both" do
              Enum.map(jobs, fn {name, prep, fun, repeats} ->
                {name, fn {a, b} -> {prep.(a), prep.(b)} end, fn {a, b} -> {fun.(a), fun.(b)} end,
                 repeats}
              end)
            else
              jobs
            end

          # Project inputs to each job's actual requirements before copying to workers.
          # This avoids retaining million-entry lists in single-offset microbenchmarks.
          prepared =
            Enum.map(jobs, fn {name, prep, fun, repeats} ->
              {name, Enum.map(inputs, prep), fun, repeats}
            end)

          Enum.each(prepared, fn {_, values, fun, _} -> Enum.each(values, fun) end)

          measurements =
            Enum.reduce(1..rounds, %{}, fn round, acc ->
              acc =
                Enum.reduce(Enum.shuffle(prepared), acc, fn {name, values, fun, repeats}, acc ->
                  us = batch(values, fun, repeats)
                  Map.update(acc, name, [us], &[us | &1])
                end)

              IO.puts("#{size} #{label}: round #{round}/#{rounds} complete")
              acc
            end)

          Enum.map(jobs, fn {name, _, _, repeats} ->
            times = Enum.sort(measurements[name])
            median = Enum.at(times, div(length(times), 2))

            IO.puts(
              "#{label} | #{name} | median #{fmt(median)} us | min #{fmt(hd(times))} | max #{fmt(List.last(times))}"
            )

            Enum.join(
              [
                size,
                label,
                name,
                fmt(median),
                fmt(hd(times)),
                fmt(List.last(times)),
                rounds,
                corpus,
                repeats
              ],
              ","
            )
          end)
        end)

      File.write!(
        prefix <> ".csv",
        "entries_per_stack,stack,operation,median_us,min_batch_us,max_batch_us,rounds,corpus,repeats\n" <>
          Enum.join(rows, "\n") <> "\n"
      )

      IO.puts("Saved #{prefix}.csv and #{prefix}_sizes.txt")
    end
  end

  defp jobs do
    [
      {"build random", & &1.random, &R.from_list/1, 1},
      {"build sorted general API", & &1.sorted, &R.from_list/1, 1},
      {"build sorted sorted API", & &1.sorted, &R.from_sorted_list/1, 1},
      {"sort only", & &1.random, &Enum.sort/1, 1},
      {"sort plus sorted build", & &1.random, fn xs -> R.from_sorted_list(Enum.sort(xs)) end, 1},
      {"insert one", &{&1.old, &1.add}, fn {old, n} -> R.insert(old, n) end, 500},
      {"remove one", &{&1.old, &1.remove}, fn {old, n} -> R.remove(old, n) end, 500},
      {"apply remove plus add", &{&1.old, &1.remove, &1.add},
       fn {old, r, a} -> old |> R.remove(r) |> R.insert(a) end, 500},
      {"diff existing old/new both ways", &{&1.old, &1.new}, fn {old, new} -> diff(old, new) end,
       2},
      {"rebuild random new plus diff", &{&1.old, &1.next_random},
       fn {old, xs} -> diff(old, R.from_list(xs)) end, 1},
      {"diff after one add", &{&1.old, &1.inserted}, fn {old, new} -> diff(old, new) end, 2},
      {"diff after one remove", &{&1.old, &1.removed}, fn {old, new} -> diff(old, new) end, 2},
      {"one add plus compute diff", &{&1.old, &1.add},
       fn {old, n} -> diff(old, R.insert(old, n)) end, 2},
      {"one remove plus compute diff", &{&1.old, &1.remove},
       fn {old, n} -> diff(old, R.remove(old, n)) end, 2}
    ]
  end

  defp sample(size) do
    values = unique(MapSet.new(), size) |> MapSet.to_list() |> Enum.shuffle()
    sorted = Enum.sort(values)
    old = R.from_list(values)
    remove = hd(values)
    add = absent(old)
    next_random = [add | tl(values)]
    new = R.from_list(next_random)
    inserted = R.insert(old, add)
    removed = R.remove(old, remove)
    true = R.size(old) == size
    true = R.to_list(old) == sorted
    true = R.from_sorted_list(sorted) == old
    true = R.insert(removed, add) == new
    true = R.size(inserted) == size + 1 and R.size(removed) == size - 1

    for {snapshot, adds, removals} <- [
          {new, [add], [remove]},
          {inserted, [add], []},
          {removed, [], [remove]}
        ] do
      {a, r} = diff(old, snapshot)
      true = R.to_list(a) == adds and R.to_list(r) == removals
    end

    %{
      random: values,
      sorted: sorted,
      old: old,
      new: new,
      next_random: next_random,
      add: add,
      remove: remove,
      inserted: inserted,
      removed: removed
    }
  end

  defp unique(set, size) do
    if MapSet.size(set) == size,
      do: set,
      else: unique(MapSet.put(set, :rand.uniform(@universe) - 1), size)
  end

  defp absent(old) do
    n = :rand.uniform(@universe) - 1
    if R.contains?(old, n), do: absent(old), else: n
  end

  defp diff(old, new), do: {R.difference(new, old), R.difference(old, new)}

  defp memory(value) do
    bitmaps = if is_tuple(value), do: Tuple.to_list(value), else: [value]
    containers = Enum.flat_map(bitmaps, &Map.values(&1.containers))
    bins = for {:array, bin} <- containers, do: bin
    # Dense BEAM bignums are already included by erts_debug.size: don't add again.
    off_heap =
      bins
      |> Enum.filter(&(byte_size(&1) > 64))
      |> Enum.map(&:binary.referenced_byte_size/1)
      |> Enum.sum()

    heap = :erts_debug.size(value) * :erlang.system_info(:wordsize)

    %{
      members: Enum.sum(Enum.map(bitmaps, &R.size/1)),
      arrays: length(bins),
      bitsets: Enum.count(containers, &match?({:bitmap, _, _}, &1)),
      logical_container_payload_bytes:
        Enum.sum(Enum.map(bins, &byte_size/1)) +
          8192 * Enum.count(containers, &match?({:bitmap, _, _}, &1)),
      beam_heap_bytes: heap,
      off_heap_binary_bytes: off_heap,
      total_bytes: heap + off_heap,
      etf_bytes: byte_size(:erlang.term_to_binary(value))
    }
  end

  defp batch(values, fun, repeats) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        :erlang.garbage_collect()
        start = System.monotonic_time()
        for _ <- 1..repeats, do: Enum.each(values, fun)
        ns = System.convert_time_unit(System.monotonic_time() - start, :native, :nanosecond)
        send(parent, {:result, self(), ns / (length(values) * repeats) / 1000})
      end)

    receive do
      {:result, ^pid, us} ->
        Process.demonitor(ref, [:flush])
        us

      {:DOWN, ^ref, :process, ^pid, reason} ->
        raise inspect(reason)
    end
  end

  defp fmt(n), do: :erlang.float_to_binary(n, decimals: 3)
end

ScaleBench.run()
