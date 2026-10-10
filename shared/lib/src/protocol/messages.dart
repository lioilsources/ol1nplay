import 'commands.dart';
import 'json_util.dart';
import 'settings.dart';
import 'state_models.dart';

/// Client → engine envelope. Only the fields the command needs are sent.
class Request {
  const Request({
    required this.id,
    required this.type,
    this.token,
    this.path,
    this.paths,
    this.dir,
    this.index,
    this.to,
    this.query,
    this.limit,
    this.samples,
    this.ms,
    this.flag,
    this.mode,
    this.which,
    this.device,
    this.backend,
    this.name,
    this.minutes,
    this.sysmode,
    this.settings,
  });

  final int id;
  final String type;
  final String? token;
  final String? path;
  final List<String>? paths;
  final String? dir;
  final int? index;
  final int? to;
  final String? query;
  final int? limit;
  final int? samples;
  final int? ms;

  /// Wire name is `bool`.
  final bool? flag;
  final String? mode;

  /// ab.nudge: "a" | "b".
  final String? which;
  final String? device;
  final String? backend;
  final String? name;
  final int? minutes;
  final Sysmode? sysmode;

  /// Sent as a partial object for settings.set.
  final Json? settings;

  Json toJson() => compact({
    'id': id,
    'type': type,
    'token': token,
    'path': path,
    'paths': paths,
    'dir': dir,
    'index': index,
    'to': to,
    'query': query,
    'limit': limit,
    'samples': samples,
    'ms': ms,
    'bool': flag,
    'mode': mode,
    'which': which,
    'device': device,
    'backend': backend,
    'name': name,
    'minutes': minutes,
    'sysmode': sysmode?.toJson(),
    'settings': settings,
  });

  factory Request.fromJson(Json j) => Request(
    id: integer(j, 'id'),
    type: str(j, 'type'),
    token: j['token'] as String?,
    path: j['path'] as String?,
    paths: j['paths'] is List ? strings(j, 'paths') : null,
    dir: j['dir'] as String?,
    index: j['index'] as int?,
    to: j['to'] as int?,
    query: j['query'] as String?,
    limit: j['limit'] as int?,
    samples: j['samples'] as int?,
    ms: j['ms'] as int?,
    flag: j['bool'] as bool?,
    mode: j['mode'] as String?,
    which: j['which'] as String?,
    device: j['device'] as String?,
    backend: j['backend'] as String?,
    name: j['name'] as String?,
    minutes: j['minutes'] as int?,
    sysmode: obj(j, 'sysmode') == null
        ? null
        : Sysmode.fromJson(obj(j, 'sysmode')!),
    settings: obj(j, 'settings'),
  );
}

/// Engine → client answer to exactly one [Request].
class Response {
  const Response({
    required this.id,
    required this.ok,
    this.error = '',
    this.data,
  });

  final int id;
  final bool ok;
  final String error;
  final dynamic data;

  factory Response.fromJson(Json j) => Response(
    id: integer(j, 'id'),
    ok: boolean(j, 'ok'),
    error: str(j, 'error'),
    data: j['data'],
  );

  Json toJson() => compact({
    'id': id,
    'type': Ev.result,
    'ok': ok,
    'error': error,
    'data': data,
  });

  /// Convenience for building a reply to [r].
  static Json okFor(int id, [Object? data]) =>
      Response(id: id, ok: true, data: data).toJson();
  static Json errFor(int id, String error) =>
      Response(id: id, ok: false, error: error).toJson();
}

/// Unsolicited engine → client message.
class Event {
  const Event({required this.type, this.data});

  final String type;
  final dynamic data;

  factory Event.fromJson(Json j) =>
      Event(type: str(j, 'type'), data: j['data']);

  Json toJson() => compact({'type': type, 'data': data});

  Json get dataMap =>
      data is Map ? Map<String, dynamic>.from(data as Map) : const {};
}

/// Thrown by the client when the engine answers ok=false.
class EngineException implements Exception {
  const EngineException(this.command, this.message);

  final String command;
  final String message;

  @override
  String toString() => 'EngineException($command): $message';
}

/// Re-exported so callers can build a settings patch without importing the
/// model file directly.
typedef SettingsPatch = Json;

/// Helper to turn a full [Settings] into a patch against [base].
SettingsPatch settingsPatch(Settings next, Settings base) => next.toPatch(base);
