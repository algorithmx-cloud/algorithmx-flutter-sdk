/// AlgorithmX's Flutter API.
///
/// Start with [AlgorithmX.instance.initialize], then register the device's push
/// token and call [AlgorithmX.instance.identifyUser] when a user signs in.
/// Native Android and iOS SDKs retain responsibility for notification routing,
/// campaign WebViews, and display rules.
library algorithmx_flutter;

export 'src/algorithmx.dart';
export 'src/events.dart';
