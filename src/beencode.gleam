import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list

// --- TYPES -------------------------------------------------------------------

/// A [bencoded](https://en.wikipedia.org/wiki/Bencode) value.
///
pub type BValue {
  /// The bencoding specification doesn't enforce strings to be utf8-encoded.
  /// This means a bencoded string is represented as a Gleam's `BitArray` and
  /// not a `String` that would have to be utf8-encoded.
  ///
  BString(BitArray)

  BInt(Int)

  BList(List(BValue))

  BDict(Dict(BitArray, BValue))
}

/// An error that might take place while trying to decode a bencoded
/// value with the [`decode`](#decode) function.
///
pub type BDecodeError {
  /// This happens if after decoding a `BValue` we haven't consumed the entire
  /// `BitArray` and we still have some other leftover bytes.
  ///
  /// ```txt
  /// i123ei1e
  /// ┬───╴┬──
  /// │    ╰─ After consuming the first integer we're
  /// │       left with this piece here but the only way to have
  /// │       multiple values would be to wrap everything
  /// │       into a list. This is an invalid bencoded string!
  /// │
  /// ╰─ This is consumed just fine.
  /// ```
  ///
  ExpectingEof

  /// This happens if we unexpectedly reach the end of the `BitArray` while in
  /// the middle of parsing a value.
  ///
  UnexpectedEof

  UnexpectedChar(byte_index: Int)

  /// This happens if we run into the invalid empty number `ie`. A number should
  /// have at least a digit between its start `i` and its end `e`.
  ///
  EmptyNumber(byte_index: Int)

  /// This happens if we find `i-0e` which is not allowed by the bencoding
  /// specification.
  /// Zero should only be encoded as `i0e`.
  ///
  NegativeZero(byte_index: Int)

  /// This happens if a bencoded integer starts with one or more leading zeros,
  /// which is not allowed by the bencoding specification.
  ///
  /// ```txt
  /// i001e
  ///  ┬─
  ///  ╰─ The leading zeros are not allowed,
  ///     this should just be `i1e`.
  /// ```
  ///
  LeadingZero(byte_index: Int)

  /// This happens if a key of a dictionary is anything else besides a bencoded
  /// string.
  ///
  /// ```txt
  /// di1e2:aae
  ///  ┬─╴
  ///  ╰─ This key is an integer, not a string.
  /// ```
  ///
  InvalidDictKey(byte_index: Int)

  /// This happens if the specified length of a bencoded string is longer than
  /// the actual string following the `:`.
  ///
  /// ```txt
  /// 10:aa
  /// ┬─
  /// ╰─ According to this the string should be 10-bytes
  ///    long, but there's only two bytes here!
  /// ```
  StringShorterThanExpected(byte_index: Int)
}

// --- DECODING ----------------------------------------------------------------

/// Decodes a [bencoded](https://en.wikipedia.org/wiki/Bencode) `BitArray` into
/// a `BValue`.
///
/// > ⚠️ According to the bencode specification the keys of a dictionary should
/// > always be sorted lexicographically. This decoder is a bit more permissive
/// > and will successfully decode a dictionary even if its keys appear in a
/// > different order.
///
/// ## Examples
///
/// ```gleam
/// decode(<<"i1e":utf8>>)
/// // -> BInt(1)
///
/// decode(<<"6:wibble":utf8>>)
/// // -> BString("wibble")
///
/// decode(<<"li1e6:wibblee":utf8>>)
/// // -> BList([BInt(1), BString("wibble")])
///
/// decode(<<"d6:wibblei1ee">>)
/// // -> BDict(dict.from_list([#(BInt(1), BString("wibble"))]))
/// ```
///
pub fn decode(input: BitArray) -> Result(BValue, BDecodeError) {
  case decode_value(input, 0) {
    // After decoding a value we want to make sure we've consumed the whole
    // thing. If there's a remaining bit that means that we have a malformed
    // bencoded string:
    //
    //     i123ei1e
    //     ┬───╴┬──
    //     │    ╰─ After consuming the first integer we're left with this string
    //     │       but the only way to have multiple values would be to wrap
    //     │       everything into a list. This is an invalid bencoded string!
    //     │
    //     ╰─ This is consumed just fine.
    //
    Ok(#(value, <<>>, _)) -> Ok(value)
    Ok(#(_, _, _)) -> Error(ExpectingEof)

    // We just pass along any other error that might have happened in the
    // decoding.
    Error(reason) -> Error(reason)
  }
}

fn decode_value(
  string: BitArray,
  byte_index: Int,
) -> Result(#(BValue, BitArray, Int), BDecodeError) {
  case string {
    // --- NUMBERS
    //
    // A number must have some kind of digits between the starting `i` and
    // closing `e`.
    <<"ie":utf8, _:bits>> -> Error(EmptyNumber(byte_index))

    // We special handle the number zero which is `i0e`, this makes it easier to
    // catch other error cases like negative zero and leading zeros.
    <<"i0e":utf8, rest:bits>> -> Ok(#(BInt(0), rest, byte_index + 1))

    // Negative zero is not allowed: zero must always be encoded as `i0e`.
    <<"i-0e":utf8, _:bits>> -> Error(NegativeZero(byte_index))

    // If we find a leading zero (and we know the number is not zero bacause
    // otherwise it would have matched with the previous branches) we return an
    // error since leading zeros are not allowed.
    <<"i0":utf8, _:bits>> | <<"i-0":utf8, _:bits>> ->
      Error(LeadingZero(byte_index))

    // We've found a valid number and we can parse it. We just have to be
    // careful about the sign, so if it starts with a `-` we tell `decode_int`
    // that it is a negative number.
    <<"i-":utf8, rest:bits>> -> decode_int(rest, 0, True, byte_index)
    <<"i":utf8, rest:bits>> -> decode_int(rest, 0, False, byte_index)

    // --- COMPOSITE STRUCTURES
    //
    <<"l":utf8, rest:bits>> -> decode_list(rest, [], byte_index)
    <<"d":utf8, rest:bits>> -> decode_dict(rest, dict.new(), byte_index)

    // --- STRINGS
    //
    // We special handle the zero-length string that is always encoded as `0:`.
    <<"0:":utf8, rest:bits>> -> Ok(#(BString(<<>>), rest, byte_index + 2))

    // If we then find a leading zero that is not followed by `:` (that is the
    // empty string) then we immediately return an error.
    <<"0":utf8, _:bits>> -> Error(UnexpectedChar(byte_index))

    // If we find any other number we have a (possibly valid) string length and
    // we start decoding it.
    <<"1":utf8, _:bits>>
    | <<"2":utf8, _:bits>>
    | <<"3":utf8, _:bits>>
    | <<"4":utf8, _:bits>>
    | <<"5":utf8, _:bits>>
    | <<"6":utf8, _:bits>>
    | <<"7":utf8, _:bits>>
    | <<"8":utf8, _:bits>>
    | <<"9":utf8, _:bits>> -> decode_string(string, 0, byte_index + 1)

    // --- FALLBACK ERRORS
    //
    <<>> -> Error(UnexpectedEof)
    _ -> Error(UnexpectedChar(byte_index))
  }
}

// We call this function once we find a valid start for a string.
// This function will first consume `string` until it gets to a `:` and then
// consume a string with that given length:
//
//     13:gleam_is_cool
//     ┬─
//     ╰─ We first consume this part digit-by-digit accumulating the decoded
//        length in `acc`.
//
//     13:gleam_is_cool
//        ┬────────────
//        ╰─ Once we know the length we can just take the following 13 bytes.
//
// Taking a slice of a `BitArray` this way is a constant time operation that
// doesn't make any copies of the original `BitArray`, so it's really efficient!
//
fn decode_string(
  string: BitArray,
  acc: Int,
  byte_index: Int,
) -> Result(#(BValue, BitArray, Int), BDecodeError) {
  case string {
    // If we find a new digit we update the length of the string. To understand
    // why this operation makes sense imagine you have a string with length 123:
    //
    //     123:
    //     ┬
    //     ╰─ We'll start by finding a one, so `acc` will become `1`.
    //
    //     123:
    //      ┬
    //      ╰─ In the following recursive function we find a two, so `acc` will
    //         become `12`.
    //
    //     123:
    //       ┬
    //       ╰─ Last we find a three so we have to multiply the accumulator one
    //          last time and add 3, obtaining `123`.
    //
    <<"0":utf8, rest:bits>> -> decode_string(rest, acc * 10, byte_index + 1)
    <<"1":utf8, rest:bits>> -> decode_string(rest, acc * 10 + 1, byte_index + 1)
    <<"2":utf8, rest:bits>> -> decode_string(rest, acc * 10 + 2, byte_index + 1)
    <<"3":utf8, rest:bits>> -> decode_string(rest, acc * 10 + 3, byte_index + 1)
    <<"4":utf8, rest:bits>> -> decode_string(rest, acc * 10 + 4, byte_index + 1)
    <<"5":utf8, rest:bits>> -> decode_string(rest, acc * 10 + 5, byte_index + 1)
    <<"6":utf8, rest:bits>> -> decode_string(rest, acc * 10 + 6, byte_index + 1)
    <<"7":utf8, rest:bits>> -> decode_string(rest, acc * 10 + 7, byte_index + 1)
    <<"8":utf8, rest:bits>> -> decode_string(rest, acc * 10 + 8, byte_index + 1)
    <<"9":utf8, rest:bits>> -> decode_string(rest, acc * 10 + 9, byte_index + 1)

    // When we find a `:` we're done consuming the string length and we can take
    // that many bytes from the string. Pattern matching makes this a breeze and
    // super efficient as well!
    <<":":utf8, rest:bits>> ->
      case rest {
        <<string:bytes-size(acc), rest:bits>> ->
          Ok(#(BString(string), rest, byte_index + 1 + acc))
        _ -> Error(StringShorterThanExpected(byte_index))
      }

    <<>> -> Error(UnexpectedEof)
    _ -> Error(UnexpectedChar(byte_index))
  }
}

// The code for decoding integers will look almost exactly the same as the one
// we have written to decode the length of a string. You can have a look at the
// comments there to get an idea of how this works.
//
fn decode_int(
  string: BitArray,
  acc: Int,
  negative: Bool,
  byte_index: Int,
) -> Result(#(BValue, BitArray, Int), BDecodeError) {
  case string {
    // Once we're done we return `acc` which will hold the value of the parsed
    // number. We just have to be careful to return a negative number the caller
    // is asking for a negative one.
    //
    // Notice how nice this code is: we don't have to deal with the hyphen
    // prefix and possibly wrong encodings (eg. `i-0e`, `i01e`) since the outer
    // `decode_value` already takes care of that. Here we can just focus on the
    // happy path!
    <<"e":utf8, rest:bits>> if negative ->
      Ok(#(BInt(-acc), rest, byte_index + 1))
    <<"e":utf8, rest:bits>> -> Ok(#(BInt(acc), rest, byte_index + 1))

    <<"0":utf8, rest:bits>> ->
      decode_int(rest, acc * 10, negative, byte_index + 1)
    <<"1":utf8, rest:bits>> ->
      decode_int(rest, acc * 10 + 1, negative, byte_index + 1)
    <<"2":utf8, rest:bits>> ->
      decode_int(rest, acc * 10 + 2, negative, byte_index + 1)
    <<"3":utf8, rest:bits>> ->
      decode_int(rest, acc * 10 + 3, negative, byte_index + 1)
    <<"4":utf8, rest:bits>> ->
      decode_int(rest, acc * 10 + 4, negative, byte_index + 1)
    <<"5":utf8, rest:bits>> ->
      decode_int(rest, acc * 10 + 5, negative, byte_index + 1)
    <<"6":utf8, rest:bits>> ->
      decode_int(rest, acc * 10 + 6, negative, byte_index + 1)
    <<"7":utf8, rest:bits>> ->
      decode_int(rest, acc * 10 + 7, negative, byte_index + 1)
    <<"8":utf8, rest:bits>> ->
      decode_int(rest, acc * 10 + 8, negative, byte_index + 1)
    <<"9":utf8, rest:bits>> ->
      decode_int(rest, acc * 10 + 9, negative, byte_index + 1)

    <<>> -> Error(UnexpectedEof)
    _ -> Error(UnexpectedChar(byte_index))
  }
}

fn decode_list(
  string: BitArray,
  acc: List(BValue),
  byte_index: Int,
) -> Result(#(BValue, BitArray, Int), BDecodeError) {
  case string {
    // If we get to the end we just return the accumulated parsed values.
    <<"e":utf8, rest:bits>> ->
      Ok(#(BList(list.reverse(acc)), rest, byte_index + 1))

    // Otherwise we decode a single value and keep going until we get to the
    // end of the list.
    _ ->
      case decode_value(string, byte_index) {
        Error(error) -> Error(error)
        Ok(#(value, rest, byte_index)) ->
          decode_list(rest, [value, ..acc], byte_index)
      }
  }
}

// ⚠️ A key difference from the specification is that we're a bit more
// permissive with regard to dicitonaries.
// The specification says that the keys should always apear in lexicographical
// order, while we allow them to be in any order.
//
fn decode_dict(
  string: BitArray,
  acc: Dict(BitArray, BValue),
  byte_index: Int,
) -> Result(#(BValue, BitArray, Int), BDecodeError) {
  case string {
    // If we get to the end we just return the accumulated parsed dictionary.
    <<"e":utf8, rest:bits>> -> Ok(#(BDict(acc), rest, byte_index + 1))

    // Otherwise we decode a key and a value and keep going until we get to the
    // end of the dictionary.
    _ ->
      case decode_value(string, byte_index) {
        Error(error) -> Error(error)

        // The key must be a string according to the spec. So if it is anything
        // else we say it's invalid.
        Ok(#(BString(key), rest, byte_index)) ->
          // If the key is valid we can go on and parse a value as well.
          case decode_value(rest, byte_index) {
            Error(error) -> Error(error)
            Ok(#(value, rest, byte_index)) ->
              decode_dict(rest, dict.insert(acc, key, value), byte_index)
          }

        Ok(#(_, _, byte_index)) -> Error(InvalidDictKey(byte_index))
      }
  }
}

// --- ENCODING ----------------------------------------------------------------

/// Encodes a `BValue` into a [bencoded](https://en.wikipedia.org/wiki/Bencode)
/// `BitArray`.
///
/// ## Examples
///
/// ```gleam
/// encode(BInt(1))
/// // -> <<"i1e":utf8>>
///
/// encode(BString("wibble"))
/// // -> <<"6:wibble":utf8>>
///
/// encode(BList([BInt(1), BString("wibble")]))
/// // -> <<"li1e6:wibblee":utf8>>
///
/// encode(BDict(dict.from_list([#(BInt(1), BString("wibble"))])))
/// // -> <<"d6:wibblei1ee">>
/// ```
///
pub fn encode(value: BValue) -> BitArray {
  case value {
    BInt(n) -> <<"i":utf8, int.to_string(n):utf8, "e":utf8>>

    BString(value) -> {
      let bytes = bit_array.byte_size(value)
      <<int.to_string(bytes):utf8, ":":utf8, value:bits>>
    }

    BList(values) -> {
      let encoded_values = list.map(values, encode)
      <<"l":utf8, bit_array.concat(encoded_values):bits, "e":utf8>>
    }

    BDict(dict) -> {
      let values =
        dict.to_list(dict)
        |> list.sort(fn(one, other) {
          let #(one_key, _one_value) = one
          let #(other_key, _other_value) = other
          bit_array.compare(one_key, other_key)
        })
        |> list.map(fn(pair) {
          let #(key, value) = pair
          <<encode(BString(key)):bits, encode(value):bits>>
        })

      <<"d":utf8, bit_array.concat(values):bits, "e":utf8>>
    }
  }
}
