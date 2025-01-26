# 🐝 Beencode

[Bencode](https://en.wikipedia.org/wiki/Bencode) (pronounced _Bee-encode_)
encoding and decoding in Gleam.

```gleam
pub fn main() {
  decode(<<"li1e6:wibblee":utf8>>)
  // -> BList([BInt(1), BString("wibble")])
}
```
