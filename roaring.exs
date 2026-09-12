defmodule PureRoaring do
  @moduledoc """
  Immutable, dependency-free Roaring PoC for unsigned 32-bit offsets.
  High 16 bits select a container. Sparse containers use packed, sorted uint16
  binaries; above 4096 members, containers use a BEAM integer as a bitset.
  No run containers or portable serialization codec are implemented.
  """
  import Bitwise
  defstruct containers: %{}

  def from_list(values), do: values |> Enum.sort() |> from_sorted_list()

  # Accepts nondecreasing input, deduplicates, and rejects invalid offsets.
  def from_sorted_list(values) do
    {containers, high, lows, _previous} =
      Enum.reduce(values, {%{}, nil, [], -1}, fn value, {cs, high, lows, previous} ->
        validate!(value)
        if value < previous, do: raise(ArgumentError, "input must be sorted")
        key = value >>> 16

        cond do
          value == previous -> {cs, high, lows, previous}
          key == high -> {cs, high, [value &&& 65535 | lows], value}
          true -> {flush(cs, high, lows), key, [value &&& 65535], value}
        end
      end)

    %__MODULE__{containers: flush(containers, high, lows)}
  end

  def insert(%__MODULE__{containers: cs} = bitmap, value) do
    validate!(value)
    high = value >>> 16
    low = value &&& 65535
    container = Map.get(cs, high, {:array, <<>>})
    %{bitmap | containers: Map.put(cs, high, add(container, low))}
  end

  def remove(%__MODULE__{containers: cs} = bitmap, value) do
    validate!(value)
    high = value >>> 16

    case Map.fetch(cs, high) do
      :error ->
        bitmap

      {:ok, container} ->
        %{bitmap | containers: put_container(cs, high, delete(container, value &&& 65535))}
    end
  end

  def contains?(%__MODULE__{containers: cs}, value) do
    validate!(value)

    case Map.get(cs, value >>> 16) do
      nil -> false
      {:array, bin} -> elem(locate(bin, value &&& 65535), 1)
      {:bitmap, bits, _n} -> (bits &&& 1 <<< (value &&& 65535)) != 0
    end
  end

  def size(%__MODULE__{containers: cs}) do
    Enum.reduce(cs, 0, fn
      {_, {:array, bin}}, n -> n + div(byte_size(bin), 2)
      {_, {:bitmap, _, count}}, n -> n + count
    end)
  end

  def to_list(%__MODULE__{containers: cs}) do
    cs
    |> Enum.sort()
    |> Enum.flat_map(fn {high, container} ->
      Enum.map(lows(container), &((high <<< 16) + &1))
    end)
  end

  # a \\ b: members in a but absent from b.
  def difference(%__MODULE__{containers: a}, %__MODULE__{containers: b}) do
    cs =
      Enum.reduce(a, %{}, fn {key, left}, acc ->
        result =
          case Map.get(b, key) do
            nil -> left
            right when right == left -> {:array, <<>>}
            right -> subtract(left, right)
          end

        put_container(acc, key, result)
      end)

    %__MODULE__{containers: cs}
  end

  defp validate!(n) when is_integer(n) and n >= 0 and n <= 0xFFFFFFFF, do: :ok
  defp validate!(_), do: raise(ArgumentError, "offset must be an unsigned 32-bit integer")
  defp flush(cs, nil, _), do: cs
  defp flush(cs, key, reversed), do: Map.put(cs, key, pack(Enum.reverse(reversed)))
  defp put_container(cs, key, {:array, <<>>}), do: Map.delete(cs, key)
  defp put_container(cs, key, container), do: Map.put(cs, key, container)

  defp pack(values) do
    if length(values) <= 4096 do
      {:array, for(value <- values, into: <<>>, do: <<value::unsigned-little-16>>)}
    else
      {:bitmap, Enum.reduce(values, 0, fn value, bits -> bits ||| 1 <<< value end),
       length(values)}
    end
  end

  defp lows({:array, bin}), do: for(<<value::unsigned-little-16 <- bin>>, do: value)

  defp lows({:bitmap, bits, _}),
    do: for(value <- 0..65535, (bits &&& 1 <<< value) != 0, do: value)

  defp locate(bin, low), do: locate(bin, low, 0, div(byte_size(bin), 2))
  defp locate(_bin, _low, first, last) when first == last, do: {first * 2, false}

  defp locate(bin, low, first, last) do
    mid = div(first + last, 2)
    <<value::unsigned-little-16>> = binary_part(bin, mid * 2, 2)

    cond do
      value == low -> {mid * 2, true}
      value < low -> locate(bin, low, mid + 1, last)
      true -> locate(bin, low, first, mid)
    end
  end

  defp add({:array, bin} = container, low) do
    case locate(bin, low) do
      {_, true} ->
        container

      {pos, false} ->
        <<head::binary-size(^pos), tail::binary>> = bin
        result = {:array, head <> <<low::unsigned-little-16>> <> tail}
        if byte_size(bin) == 8192, do: pack(lows(result)), else: result
    end
  end

  defp add({:bitmap, bits, count} = container, low) do
    mask = 1 <<< low
    if (bits &&& mask) != 0, do: container, else: {:bitmap, bits ||| mask, count + 1}
  end

  defp delete({:array, bin} = container, low) do
    case locate(bin, low) do
      {_, false} ->
        container

      {pos, true} ->
        <<head::binary-size(^pos), _::16, tail::binary>> = bin
        {:array, head <> tail}
    end
  end

  defp delete({:bitmap, bits, count} = container, low) do
    mask = 1 <<< low

    if (bits &&& mask) == 0 do
      container
    else
      result = {:bitmap, bits &&& bnot(mask), count - 1}
      if count == 4097, do: pack(lows(result)), else: result
    end
  end

  defp subtract({:array, a}, {:array, b}),
    do: {:array, merge_difference(a, b, []) |> Enum.reverse() |> IO.iodata_to_binary()}

  defp subtract({:bitmap, a, _}, {:bitmap, b, _}) do
    bits = a &&& bnot(b)
    pack(lows({:bitmap, bits, 0}))
  end

  defp subtract(a, b) do
    other = %__MODULE__{containers: %{0 => b}}
    pack(Enum.reject(lows(a), &contains?(other, &1)))
  end

  defp merge_difference(<<>>, _b, acc), do: acc
  defp merge_difference(a, <<>>, acc), do: [a | acc]

  defp merge_difference(
         <<x::unsigned-little-16, xs::binary>> = a,
         <<y::unsigned-little-16, ys::binary>> = b,
         acc
       ) do
    cond do
      x < y -> merge_difference(xs, b, [<<x::unsigned-little-16>> | acc])
      x > y -> merge_difference(a, ys, acc)
      true -> merge_difference(xs, ys, acc)
    end
  end
end
