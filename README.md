# warp-grpc

A slowly getting in shape gRPC server implementation on top of Warp's HTTP2
handler.  The lib also contains a demo sever using the awesome `grpcb.in`
Proto.

## Usage

### Prerequisites

In addition to a working Haskell dev environment, you need to:
- build the `proto-lens-protoc` executable (`proto-lens`)
- install the `protoc` executable

### Adding .proto files to a Haskell package

In order to run gRPC:

- generate the `Proto` stubs in some `gen` directory

A single `protoc` invocation may be enough for both Proto and GRPC outputs:

```bash
protoc  "--plugin=protoc-gen-haskell-protolens=${protolens}" \
    --haskell-protolens_out=./gen \
    -I "${protodir1} \
    -I "${protodir2} \
    ${first.proto} \
    ${second.proto}
```

- add the `gen` sourcedir for the generated to your .cabal/package.yaml file (cf. 'hs-source-dirs').
- add the generated Proto modules to the 'exposed-modules' (or 'other-modules') keys

A reliable way to list the module names is the following bash invocation:

```bash
find gen -name "*.hs" | sed -e 's/gen\///' | sed -e 's/\.hs$//' | tr '/' '.'
```

Unlike `proto-lens`, this project does not yet provide a modified `Setup.hs`.
As a result, we cannot automate these steps from within Cabal/Stack. Hence,
you'll have to automate these steps outside your Haskell toolchain.


### Build a certificate

In shell,

```shell
openssl genrsa -out key.pem 2048
openssl req -new -key key.pem -out certificate.csr
openssl x509 -req -in certificate.csr -signkey key.pem -out certificate.pem
```

### Build and run the example binary

- stack build
- stack exec -- warp-grpc-exe

Note that you'll need a patched Warp using https://github.com/yesodweb/wai/pull/711 .

## Design

The library implements gRPC using a WAI middleware for a set of gRPC endpoints.
Endpoint handlers differ depending of the streaming/unary-ty of individual
RPCs. Bidirectional streams will be supported next.

There is little specification around the expected allowed observable states in
gRPC, hence the types this library presents make conservative choices: unary
RPCs expect an input before providing an output. Client stream allows to return
an output only when the client has stopped streaming. Server streams wait for
an input before starting to iterate sending outputs.

## Next steps

* Split the `grpcb.in` example from the lib.
* Handler type for bidirectional streams.

## Caveats

* Only supports "h2" with TLS (I'd argue it's a feature, not a bug. Don't @-me)
