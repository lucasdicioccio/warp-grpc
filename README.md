# warp-grpc

DISCLAIMER: do not use yet

A (still experimental) gRPC server implementation on top of warp's http2.
Also contains a demo sever using the awesome `grpcb.in` Proto.

## How to run the demo

- First, clone and build (including generating code from protos) `http2-client-grpc` run in a project.
- Follow instructions at `http2-client-grpc-exe` to install prerequisites
- Run the `prepare.sh` script as well
- Build a certificate
        ```shell
        openssl genrsa -out key.pem 2048
        openssl req -new -key key.pem -out certificate.csr
        openssl x509 -req -in certificate.csr -signkey key.pem -out certificate.pem
        ```
- stack build
- stack exec -- warp-grpc-exe

## Next steps

* Proper types for streaming handlers (e.g., to carry a state around). Current setup is too ad-hoc.
* Unify common pieces with `http2-client-grpc`
* Modify `http2-client-grpc` generator to create a `data` record per service, hence typechecking that servers implement the right set of handlers
* Unify {Unary,ClientStream,ServerStream}Handler (maybe around an `mtl` like set of typeclasses)
* Split the `grpcb.in` example from the lib.

## Caveats

* Only supports "h2" with TLS.
* Needs a patched `warp` (need to upstream the workaround and find time to make a proper fix)
