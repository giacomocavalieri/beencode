# 🐝 Beencode

A fast Gleam [Bencode](https://en.wikipedia.org/wiki/Bencode) library.

To add this to your project you can:

```shell
gleam add beencode@1
```

```gleam
import beencode.{BInt, BList, BString}

pub fn main() {
  let assert Ok(BList([BInt(1), BString("wibble")])) =
    beencode.decode(<<"li1e6:wibblee":utf8>>)

  let assert <<"li1e6:wibblee":utf8>> =
    beencode.encode(BList([BInt(1), BString("wibble")]))
}
```
