Code.require_file("roaring.exs", __DIR__)
ExUnit.start()

defmodule PureRoaringTest do
  use ExUnit.Case
  alias PureRoaring, as: R

  test "empty, duplicates, uint32 boundaries, and invalid inputs" do
    values = [0, 65535, 65536, 2_097_151, 0xFFFFFFFF, 0]
    bitmap = R.from_list(values)
    assert R.to_list(bitmap) == Enum.sort(Enum.uniq(values))
    assert R.size(bitmap) == 5
    assert R.from_sorted_list([]) == %R{}
    assert Enum.reduce(values, bitmap, &R.remove(&2, &1)) == %R{}
    assert R.insert(bitmap, 0) == bitmap
    assert R.remove(bitmap, 17) == bitmap

    for bad <- [-1, 0x100000000, 1.5, :bad] do
      assert_raise ArgumentError, fn -> R.from_list([bad]) end
      assert_raise ArgumentError, fn -> R.insert(bitmap, bad) end
      assert_raise ArgumentError, fn -> R.remove(bitmap, bad) end
      assert_raise ArgumentError, fn -> R.contains?(bitmap, bad) end
    end

    assert_raise ArgumentError, fn -> R.from_sorted_list([2, 1]) end
  end

  test "promote and demote around 4096, including the top bit" do
    sparse = R.from_list(0..4095)
    assert {:array, _} = sparse.containers[0]
    dense = R.insert(sparse, 65535)
    assert {:bitmap, _, 4097} = dense.containers[0]
    assert R.size(dense) == 4097
    assert R.contains?(dense, 65535)
    assert R.insert(dense, 65535) == dense
    assert R.remove(dense, 5000) == dense
    assert R.remove(dense, 65535) == sparse
    denser = R.insert(dense, 60000)
    assert R.size(denser) == 4098
    assert R.remove(denser, 60000) == dense
    assert R.to_list(dense) == Enum.to_list(0..4095) ++ [65535]
  end

  test "differences across every array/bitmap combination" do
    sets = [
      [],
      [0, 10, 65535, 65536],
      Enum.to_list(0..5000),
      Enum.to_list(3000..8000) ++ [65535, 65536]
    ]

    for a <- sets, b <- sets do
      expected = MapSet.difference(MapSet.new(a), MapSet.new(b)) |> Enum.sort()
      assert R.to_list(R.difference(R.from_list(a), R.from_list(b))) == expected
    end
  end

  test "seeded random updates and independent differences agree with MapSet" do
    :rand.seed(:exsss, {40, 50, 60})

    {bitmap, set} =
      Enum.reduce(1..2000, {%R{}, MapSet.new()}, fn _, {bitmap, set} ->
        n = :rand.uniform(200_000) - 1

        {next, expected} =
          if :rand.uniform(3) == 1 do
            {R.remove(bitmap, n), MapSet.delete(set, n)}
          else
            {R.insert(bitmap, n), MapSet.put(set, n)}
          end

        assert R.contains?(next, n) == MapSet.member?(expected, n)
        assert R.size(next) == MapSet.size(expected)
        {next, expected}
      end)

    assert R.to_list(bitmap) == Enum.sort(set)
    other = for _ <- 1..5000, do: :rand.uniform(200_000) - 1

    assert R.to_list(R.difference(bitmap, R.from_list(other))) ==
             MapSet.difference(set, MapSet.new(other)) |> Enum.sort()

    assert R.to_list(bitmap) == Enum.sort(set)
  end
end
