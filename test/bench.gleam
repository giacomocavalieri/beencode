import beencode
import gleam/list
import glychee/benchmark
import simplifile

pub fn main() {
  let assert Ok(huck_finn) =
    simplifile.read_bits("./priv/torrents/huck_finn_librivox_archive.torrent")
  let ints_list =
    list.range(1, 10_000)
    |> list.map(beencode.BInt)
    |> beencode.BList
    |> beencode.encode

  benchmark.run(
    [
      bench_function("beencode.decode", beencode.decode),
      bench_function("Bento.decode", bento_decode),
    ],
    [
      benchmark.Data("huck_finn", huck_finn),
      benchmark.Data("10k ints list", ints_list),
    ],
  )
}

@external(erlang, "Elixir.Bento", "decode!")
fn bento_decode(data: BitArray) -> Result(Nil, Nil)

fn bench_function(
  label: String,
  function: fn(data) -> a,
) -> benchmark.Function(data, Nil) {
  benchmark.Function(label, fn(data) {
    fn() {
      function(data)
      Nil
    }
  })
}
