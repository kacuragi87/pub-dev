// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library pub_server.shelf_pubserver;

import 'dart:async';
import 'dart:convert' as convert;

import 'package:http_parser/http_parser.dart';
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:shelf/shelf.dart' as shelf;
import 'package:yaml/yaml.dart';

import '../../package/backend.dart' show purgePackageCache;
import '../../shared/redis_cache.dart' show cache;

import 'repository.dart';

final Logger _logger = Logger('pubserver.shelf_pubserver');

/// It will use the pub [PackageRepository] given in the constructor to provide
/// this HTTP endpoint.
class ShelfPubServer {
  static final RegExp _packageRegexp = RegExp(r'^/api/packages/([^/]+)$');

  static final RegExp _versionRegexp =
      RegExp(r'^/api/packages/([^/]+)/versions/([^/]+)$');

  static final RegExp _addUploaderRegexp =
      RegExp(r'^/api/packages/([^/]+)/uploaders$');

  static final RegExp _removeUploaderRegexp =
      RegExp(r'^/api/packages/([^/]+)/uploaders/([^/]+)$');

  static final RegExp _downloadRegexp =
      RegExp(r'^/packages/([^/]+)/versions/([^/]+)\.tar\.gz$');

  final PackageRepository repository;

  ShelfPubServer(this.repository);

  Future<shelf.Response> requestHandler(shelf.Request request) async {
    final path = request.requestedUri.path;
    if (request.method == 'GET') {
      final downloadMatch = _downloadRegexp.matchAsPrefix(path);
      if (downloadMatch != null) {
        final package = Uri.decodeComponent(downloadMatch.group(1));
        final version = Uri.decodeComponent(downloadMatch.group(2));
        if (!isSemanticVersion(version)) return _invalidVersion(version);
        return _download(request.requestedUri, package, version);
      }

      final packageMatch = _packageRegexp.matchAsPrefix(path);
      if (packageMatch != null) {
        final package = Uri.decodeComponent(packageMatch.group(1));
        return _listVersions(request.requestedUri, package);
      }

      final versionMatch = _versionRegexp.matchAsPrefix(path);
      if (versionMatch != null) {
        final package = Uri.decodeComponent(versionMatch.group(1));
        final version = Uri.decodeComponent(versionMatch.group(2));
        if (!isSemanticVersion(version)) return _invalidVersion(version);
        return _showVersion(request.requestedUri, package, version);
      }

      if (path == '/api/packages/versions/new') {
        if (!repository.supportsUpload) {
          return shelf.Response.notFound(null);
        }

        if (repository.supportsAsyncUpload) {
          return _startUploadAsync(request.requestedUri);
        } else {
          return _startUploadSimple(request.requestedUri);
        }
      }

      if (path == '/api/packages/versions/newUploadFinish') {
        if (!repository.supportsUpload) {
          return shelf.Response.notFound(null);
        }

        if (repository.supportsAsyncUpload) {
          return _finishUploadAsync(request.requestedUri);
        } else {
          return _finishUploadSimple(request.requestedUri);
        }
      }
    } else if (request.method == 'POST') {
      if (path == '/api/packages/versions/newUpload') {
        if (!repository.supportsUpload) {
          return shelf.Response.notFound(null);
        }

        return _uploadSimple(request.requestedUri,
            request.headers['content-type'], request.read());
      } else {
        if (!repository.supportsUploaders) {
          return shelf.Response.notFound(null);
        }

        final addUploaderMatch = _addUploaderRegexp.matchAsPrefix(path);
        if (addUploaderMatch != null) {
          final package = Uri.decodeComponent(addUploaderMatch.group(1));
          return request.readAsString().then((String body) {
            return _addUploader(package, body);
          });
        }
      }
    } else if (request.method == 'DELETE') {
      if (!repository.supportsUploaders) {
        return shelf.Response.notFound(null);
      }

      final removeUploaderMatch = _removeUploaderRegexp.matchAsPrefix(path);
      if (removeUploaderMatch != null) {
        final package = Uri.decodeComponent(removeUploaderMatch.group(1));
        final user = Uri.decodeComponent(removeUploaderMatch.group(2));
        return removeUploader(package, user);
      }
    }
    return shelf.Response.notFound(null);
  }

  // Metadata handlers.

  Future<shelf.Response> _listVersions(Uri uri, String package) async {
    final cachedBinaryJson = await cache.packageData(package).get();
    if (cachedBinaryJson != null) {
      return _binaryJsonResponse(cachedBinaryJson);
    }

    final packageVersions = await repository.versions(package).toList();
    if (packageVersions.isEmpty) {
      return shelf.Response.notFound(null);
    }

    packageVersions.sort((a, b) => a.version.compareTo(b.version));

    // TODO: Add legacy entries (if necessary), such as version_url.
    Map packageVersion2Json(PackageVersion version) {
      return {
        'archive_url':
            '${_downloadUrl(uri, version.packageName, version.versionString)}',
        'pubspec': loadYaml(version.pubspecYaml),
        'version': version.versionString,
      };
    }

    var latestVersion = packageVersions.last;
    for (int i = packageVersions.length - 1; i >= 0; i--) {
      if (!packageVersions[i].version.isPreRelease) {
        latestVersion = packageVersions[i];
        break;
      }
    }

    // TODO: The 'latest' is something we should get rid of, since it's
    // duplicated in 'versions'.
    final binaryJson = convert.json.encoder.fuse(convert.utf8.encoder).convert({
      'name': package,
      'latest': packageVersion2Json(latestVersion),
      'versions': packageVersions.map(packageVersion2Json).toList(),
    });
    await cache.packageData(package).set(binaryJson);
    return _binaryJsonResponse(binaryJson);
  }

  Future<shelf.Response> _showVersion(
      Uri uri, String package, String version) async {
    final ver = await repository.lookupVersion(package, version);
    if (ver == null) {
      return shelf.Response.notFound(null);
    }

    // TODO: Add legacy entries (if necessary), such as version_url.
    return _jsonResponse({
      'archive_url': '${_downloadUrl(uri, ver.packageName, ver.versionString)}',
      'pubspec': loadYaml(ver.pubspecYaml),
      'version': ver.versionString,
    });
  }

  // Download handlers.

  Future<shelf.Response> _download(
      Uri uri, String package, String version) async {
    if (repository.supportsDownloadUrl) {
      final url = await repository.downloadUrl(package, version);
      // This is a redirect to [url]
      return shelf.Response.seeOther(url);
    }

    final stream = await repository.download(package, version);
    return shelf.Response.ok(stream);
  }

  // Upload async handlers.

  Future<shelf.Response> _startUploadAsync(Uri uri) async {
    final info = await repository.startAsyncUpload(_finishUploadAsyncUrl(uri));
    return _jsonResponse({
      'url': '${info.uri}',
      'fields': info.fields,
    });
  }

  Future<shelf.Response> _finishUploadAsync(Uri uri) async {
    try {
      final vers = await repository.finishAsyncUpload(uri);
      if (cache != null) {
        _logger.info('Invalidating cache for package ${vers.packageName}.');
        await purgePackageCache(vers.packageName);
      }
      return _jsonResponse({
        'success': {
          'message': 'Successfully uploaded package.',
        },
      });
    } on ClientSideProblem catch (error, stack) {
      _logger.info('A problem occured while finishing upload.', error, stack);
      return _jsonResponse({
        'error': {
          'message': '$error.',
        },
      }, status: 400);
    } catch (error, stack) {
      _logger.warning('An error occured while finishing upload.', error, stack);
      return _jsonResponse({
        'error': {
          'message': '$error.',
        },
      }, status: 500);
    }
  }

  // Upload custom handlers.

  shelf.Response _startUploadSimple(Uri url) {
    _logger.info('Start simple upload.');
    return _jsonResponse({
      'url': '${_uploadSimpleUrl(url)}',
      'fields': {},
    });
  }

  Future<shelf.Response> _uploadSimple(
      Uri uri, String contentType, Stream<List<int>> stream) async {
    _logger.info('Perform simple upload.');

    final boundary = _getBoundary(contentType);

    if (boundary == null) {
      return _badRequest(
          'Upload must contain a multipart/form-data content type.');
    }

    // We have to listen to all multiparts: Just doing `parts.first` will
    // result in the cancellation of the subscription which causes
    // eventually a destruction of the socket, this is an odd side-effect.
    // What we would like to have is something like this:
    //     parts.expect(1).then((part) { upload(part); })
    MimeMultipart thePart;

    await for (MimeMultipart part
        in stream.transform(MimeMultipartTransformer(boundary))) {
      // If we get more than one part, we'll ignore the rest of the input.
      if (thePart != null) {
        continue;
      }

      thePart = part;
    }

    try {
      // TODO: Ensure that `part.headers['content-disposition']` is
      // `form-data; name="file"; filename="package.tar.gz`
      final version = await repository.upload(thePart);
      if (cache != null) {
        _logger.info('Invalidating cache for package ${version.packageName}.');
        await purgePackageCache(version.packageName);
      }
      _logger.info('Redirecting to found url.');
      return shelf.Response.found(_finishUploadSimpleUrl(uri));
    } catch (error, stack) {
      _logger.warning('Error occured', error, stack);
      // TODO: Do error checking and return error codes?
      return shelf.Response.found(
          _finishUploadSimpleUrl(uri, error: error.toString()));
    }
  }

  shelf.Response _finishUploadSimple(Uri uri) {
    final error = uri.queryParameters['error'];
    if (error != null) {
      _logger.info('Finish simple upload (error: $error).');
      return _badRequest(error);
    }
    return _jsonResponse({
      'success': {'message': 'Successfully uploaded package.'}
    });
  }

  // Uploader handlers.

  Future<shelf.Response> _addUploader(String package, String body) async {
    final parts = body.split('=');
    if (parts.length == 2 && parts[0] == 'email' && parts[1].isNotEmpty) {
      try {
        final user = Uri.decodeQueryComponent(parts[1]);
        await repository.addUploader(package, user);
        return _successfullRequest('Successfully added uploader to package.');
      } on UploaderAlreadyExistsException {
        return _badRequest(
            'Cannot add an already-existent uploader to package.');
      } on UnauthorizedAccessException {
        return _unauthorizedRequest();
      } on GenericProcessingException catch (e) {
        return _badRequest(e.message);
      }
    }
    return _badRequest('Invalid request');
  }

  Future<shelf.Response> removeUploader(
      String package, String userEmail) async {
    try {
      await repository.removeUploader(package, userEmail);
      return _successfullRequest('Successfully removed uploader from package.');
    } on LastUploaderRemoveException {
      return _badRequest('Cannot remove last uploader of a package.');
    } on UnauthorizedAccessException {
      return _unauthorizedRequest();
    } on GenericProcessingException catch (e) {
      return _badRequest(e.message);
    }
  }

  // Helper functions.

  shelf.Response _invalidVersion(String version) =>
      _badRequest('Version string "$version" is not a valid semantic version.');

  Future<shelf.Response> _successfullRequest(String message) async {
    return shelf.Response(200,
        body: convert.json.encode({
          'success': {'message': message}
        }),
        headers: {'content-type': 'application/json'});
  }

  shelf.Response _unauthorizedRequest() => shelf.Response(403,
      body: convert.json.encode({
        'error': {'message': 'Unauthorized request.'}
      }),
      headers: {'content-type': 'application/json'});

  shelf.Response _badRequest(String message) => shelf.Response(400,
      body: convert.json.encode({
        'error': {'message': message}
      }),
      headers: {'content-type': 'application/json'});

  shelf.Response _binaryJsonResponse(List<int> d, {int status = 200}) =>
      shelf.Response(status,
          body: Stream.fromIterable([d]),
          headers: {'content-type': 'application/json'});

  shelf.Response _jsonResponse(Map json, {int status = 200}) =>
      shelf.Response(status,
          body: convert.json.encode(json),
          headers: {'content-type': 'application/json'});

  // Download urls.

  Uri _downloadUrl(Uri url, String package, String version) {
    final encode = Uri.encodeComponent;
    return url.resolve(
        '/packages/${encode(package)}/versions/${encode(version)}.tar.gz');
  }

  // Upload async urls.

  Uri _finishUploadAsyncUrl(Uri url) =>
      url.resolve('/api/packages/versions/newUploadFinish');

  // Upload custom urls.

  Uri _uploadSimpleUrl(Uri url) =>
      url.resolve('/api/packages/versions/newUpload');

  Uri _finishUploadSimpleUrl(Uri url, {String error}) {
    final postfix = error == null ? '' : '?error=${Uri.encodeComponent(error)}';
    return url.resolve('/api/packages/versions/newUploadFinish$postfix');
  }

  bool isSemanticVersion(String version) {
    try {
      semver.Version.parse(version);
      return true;
    } catch (_) {
      return false;
    }
  }
}

String _getBoundary(String contentType) {
  final mediaType = MediaType.parse(contentType);

  if (mediaType.type == 'multipart' && mediaType.subtype == 'form-data') {
    return mediaType.parameters['boundary'];
  }
  return null;
}
