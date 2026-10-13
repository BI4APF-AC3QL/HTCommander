// Static web server facade.
//
// On native platforms (those exposing `dart:io`) this resolves to the real
// [WebServer] backed by an `HttpServer`. Windows, Linux, macOS, and Android can
// host browser clients; Android keeps an explicitly enabled server alive with
// its foreground service. On the web — which cannot open listening sockets —
// and on iOS — where the app does not host TCP services — it resolves to an
// inert stub.
export 'web_server_stub.dart' if (dart.library.io) 'web_server_io.dart';
