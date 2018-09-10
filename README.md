# warp-grpc

A gRPC server implementation on top of Warp's HTTP2 handler.  The lib also
contains a demo sever using the awesome `grpcb.in` Proto. The current release
is an advanced technical demo, expect a few breaking changes.

## Design

The library implements gRPC using a WAI middleware for a set of gRPC endpoints.
Endpoint handlers differ depending of the streaming/unary-ty of individual
RPCs. Bidirectional streams will be supported next.

There is little specification around the expected allowed observable states in
gRPC, hence the types this library presents make conservative choices: unary
RPCs expect an input before providing an output. Client stream allows to return
an output only when the client has stopped streaming. Server streams wait for
an input before starting to iterate sending outputs.

## Usage

Generate some `proto-lens` code from `.proto` files, ideally in a separate
library.  Import this library and the generated proto-lens code to implement
handlers for the `service` stanzas defined in the `.proto` files (see
Haddocks). Finally, serve `warp` over TLS`.

## Example

Please refer to https://github.com/lucasdicioccio/warp-grpc-example for an example.

## Next steps

* Helper to set metadatas (a.k.a., headers and trailers).
  - (API-breaking) some or all handlers will get an IO-step to return extra metadata
* Helper to map request headerlists into client metadatas (probably in `http2-grpc-types`)

## Limitations

* Only supports "h2" with TLS (I'd argue it's a feature, not a bug. Don't @-me)
* Some valid gRPC applications may not be expressible directly on top of warp
  because sending HTTP2 trailers (i.e., signalling the server's desire to stop
  sending messages) is correlated with closing the HTTP2 stream (i.e., stop
  accepting client messages). Hence it's not feasible to create a bidirectional
  stream that terminates on the server end while continuing to ingest client
  messages. This use case, however, seems like a corner case.
