// Template for build/web/flutter_bootstrap.js; `flutter build web` fills in
// the two placeholders.
//
// Differences from the default template:
//  * no service worker is registered, so nothing is written to Cache Storage
//    (the web app keeps no persistent state of any kind);
//  * CanvasKit is always loaded from this origin (canvaskit/), never from
//    www.gstatic.com, whatever the build flags were.
{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
  },
});
