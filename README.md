# warp-grpc

A (still experimental) gRPC server implementation on top of Warp's HTTP2 handler.
The lib also contains a demo sever using the awesome `grpcb.in` Proto.

## Usage

### Prerequisites

In addition to a working Haskell dev environment, you need to:
- build the `proto-lens-protoc` executable (`proto-lens`)
- install the `protoc` executable

### Adding .proto files to a Haskell package


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

## Next steps

* Proper types for streaming handlers (e.g., to carry a state around). Current setup is too ad-hoc.
* Unify {Unary,ClientStream,ServerStream}Handler (maybe around an `mtl` like set of typeclasses)
* Split the `grpcb.in` example from the lib.

## Caveats

* Only supports "h2" with TLS.
