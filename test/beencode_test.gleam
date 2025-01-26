import beencode.{type BValue, BDict, BInt, BList, BString}
import gleam/dict
import gleam/list
import gleam/string
import gleam/yielder
import gleeunit
import gleeunit/should
import prng/random.{type Generator}
import prng/seed
import simplifile

pub fn main() {
  gleeunit.main()
}

// --- REAL TORRENT FILES DECODING ---------------------------------------------

pub fn decode_real_torrent_files_test() {
  let assert Ok(files) = simplifile.get_files("./priv/torrents")
  let torrents = list.filter(files, string.ends_with(_, ".torrent"))

  use torrent <- list.each(torrents)
  let assert Ok(raw) = simplifile.read_bits(from: torrent)
  let assert Ok(_) = beencode.decode(raw)
}

// --- INTEGERS DECODING -------------------------------------------------------

pub fn number_roundtrip_test() -> Nil {
  use original_int <- for_all(bint())
  let assert Ok(new_int) = beencode.encode(original_int) |> beencode.decode
  new_int |> should.equal(original_int)
}

pub fn empty_integer_test() {
  let assert Error(_) = beencode.decode(<<"ie":utf8>>)
}

pub fn leading_zeros_in_positive_integer_test() {
  let assert Error(_) = beencode.decode(<<"i00e":utf8>>)
  let assert Error(_) = beencode.decode(<<"i01e":utf8>>)
  let assert Error(_) = beencode.decode(<<"i001e":utf8>>)
}

pub fn negative_zero_test() {
  let assert Error(_) = beencode.decode(<<"i-0e":utf8>>)
}

pub fn leading_zeros_in_negative_integer_test() {
  let assert Error(_) = beencode.decode(<<"i-00e":utf8>>)
  let assert Error(_) = beencode.decode(<<"i-01e":utf8>>)
  let assert Error(_) = beencode.decode(<<"i-001e":utf8>>)
}

pub fn invalid_number_test() {
  let assert Error(_) = beencode.decode(<<"i1-1e":utf8>>)
  let assert Error(_) = beencode.decode(<<"i1a1e":utf8>>)
  let assert Error(_) = beencode.decode(<<"ilee":utf8>>)
  let assert Error(_) = beencode.decode(<<"idee":utf8>>)
  let assert Error(_) = beencode.decode(<<"iwe":utf8>>)
  let assert Error(_) = beencode.decode(<<"i1i0e1e":utf8>>)
}

// --- STRING DECODING ---------------------------------------------------------

pub fn empty_string_test() {
  let assert Ok(BString(<<>>)) = beencode.decode(<<"0:":utf8>>)
}

pub fn string_roundtrip_test() {
  use original_string <- for_all(bstring())
  let assert Ok(new_string) =
    beencode.encode(original_string) |> beencode.decode
  new_string |> should.equal(original_string)
}

// --- LIST DECODING -----------------------------------------------------------

pub fn empty_list_test() {
  let assert Ok(BList([])) = beencode.decode(<<"le":utf8>>)
}

pub fn list_roundtrip_test() {
  use original_list <- for_all(blist(4))

  let assert Ok(new_list) = beencode.encode(original_list) |> beencode.decode
  new_list |> should.equal(original_list)
}

// --- DICTIONARY DECODING -----------------------------------------------------

pub fn empty_dict_test() {
  let assert Ok(BDict(dict)) = beencode.decode(<<"de":utf8>>)
  dict |> should.equal(dict.new())
}

pub fn dict_roundtrip_test() {
  use original_dict <- for_all(bdict(4))
  let assert Ok(new_dict) = beencode.encode(original_dict) |> beencode.decode
  new_dict |> should.equal(original_dict)
}

// --- GENERATORS --------------------------------------------------------------

fn for_all(generator: Generator(a), try fun: fn(a) -> b) -> Nil {
  generator
  |> random.to_yielder(seed.new(11))
  |> yielder.take(100)
  |> yielder.each(fun)
}

fn bvalue(depth: Int) -> Generator(BValue) {
  case depth {
    0 | 1 -> random.choose(bint(), bstring())
    _ ->
      random.weighted(#(3.0, bint()), [
        #(3.0, bstring()),
        #(1.0, blist(depth)),
        #(1.0, bdict(depth)),
      ])
  }
  |> random.then(fn(picked_generator) { picked_generator })
}

fn bint() -> Generator(BValue) {
  random.int(random.min_int, random.max_int)
  |> random.map(BInt)
}

fn bstring() -> Generator(BValue) {
  random.bit_array()
  |> random.map(BString)
}

fn blist(depth: Int) -> Generator(BValue) {
  random.list(bvalue(depth - 1))
  |> random.map(BList)
}

fn bdict(depth: Int) -> Generator(BValue) {
  random.dict(random.bit_array(), bvalue(depth - 1))
  |> random.map(BDict)
}
