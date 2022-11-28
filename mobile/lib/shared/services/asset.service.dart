import 'dart:async';
import 'dart:collection';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/hive_box.dart';
import 'package:immich_mobile/modules/backup/background_service/background.service.dart';
import 'package:immich_mobile/modules/backup/models/hive_backup_albums.model.dart';
import 'package:immich_mobile/modules/backup/services/backup.service.dart';
import 'package:immich_mobile/shared/models/asset.dart';
import 'package:immich_mobile/shared/models/user.dart';
import 'package:immich_mobile/shared/models/value.dart';
import 'package:immich_mobile/shared/providers/api.provider.dart';
import 'package:immich_mobile/shared/providers/db.provider.dart';
import 'package:immich_mobile/shared/services/api.service.dart';
import 'package:immich_mobile/utils/openapi_extensions.dart';
import 'package:immich_mobile/utils/tuple.dart';
import 'package:logging/logging.dart';
import 'package:isar/isar.dart';
import 'package:openapi/api.dart';
import 'package:photo_manager/photo_manager.dart';

final assetServiceProvider = Provider(
  (ref) => AssetService(
    ref.watch(apiServiceProvider),
    ref.watch(backupServiceProvider),
    ref.watch(backgroundServiceProvider),
    ref.watch(dbProvider),
  ),
);

class AssetService {
  final ApiService _apiService;
  final BackupService _backupService;
  final BackgroundService _backgroundService;
  final log = Logger('AssetService');
  final Isar _db;

  AssetService(
    this._apiService,
    this._backupService,
    this._backgroundService,
    this._db,
  );

  /// Returns `null` if the server state did not change, else list of assets
  Future<List<AssetResponseDto>?> getRemoteAssets({
    required bool hasCache,
  }) async {
    try {
      final etag =
          hasCache ? await _db.values.getStr(DbKey.remoteAssetsEtag) : null;
      final Pair<List<AssetResponseDto>, String?>? remote =
          await _apiService.assetApi.getAllAssetsWithETag(eTag: etag);
      if (remote == null) {
        return null;
      }
      if (remote.second != null) {
        await _db.writeTxn(() async =>
            await _db.values.setStr(DbKey.remoteAssetsEtag, remote.second!));
      }
      return remote.first;
    } catch (e, stack) {
      log.severe('Error while getting remote assets', e, stack);
      return null;
    }
  }

  Future<bool> fetchRemoteAssets() async {
    final Stopwatch sw = Stopwatch()..start();
    final int c = await _db.assets.where().remoteIdIsNotNull().count();
    final List<AssetResponseDto>? dtos = await getRemoteAssets(hasCache: c < 0);
    if (dtos == null) {
      debugPrint("fetchRemoteAssets fast took ${sw.elapsedMilliseconds}ms");
      return false;
    }

    final HashSet<String> existingRemoteIds = HashSet.from(
      await _db.assets.where().remoteIdIsNotNull().remoteIdProperty().findAll(),
    );
    final HashSet<String> allRemoteIds = HashSet.from(dtos.map((e) => e.id));

    final HashMap<String, User?> userMap = HashMap();
    final List<Asset> assets =
        dtos.where((e) => !existingRemoteIds.contains(e.id)).map((dto) {
      final User? owner = userMap.putIfAbsent(
          dto.ownerId, () => _db.users.getByIdSync(dto.ownerId));
      final Asset a = Asset.remote(dto);
      a.owner.value = owner;
      return a;
    }).toList(growable: false);

    final deletedAssetIds = existingRemoteIds.difference(allRemoteIds);

    if (assets.isEmpty && deletedAssetIds.isEmpty) {
      debugPrint("fetchRemoteAssets medium took ${sw.elapsedMilliseconds}ms");
      return false;
    }
    await _db.writeTxn(() async {
      if (deletedAssetIds.isNotEmpty) {
        await _db.assets.deleteAllByRemoteId(deletedAssetIds);
      }
      if (assets.isNotEmpty) {
        await _db.assets.putAll(assets);
        await Future.wait(assets.map((e) => e.owner.save()));
      }
    });
    debugPrint("fetchRemoteAssets full took ${sw.elapsedMilliseconds}ms");
    return true;
  }

  /// if [urgent] is `true`, do not block by waiting on the background service
  /// to finish running. Returns `null` instead after a timeout.
  Future<List<AssetEntity>?> getLocalAssets({bool urgent = false}) async {
    try {
      final Future<bool> hasAccess = urgent
          ? _backgroundService.hasAccess
              .timeout(const Duration(milliseconds: 250))
          : _backgroundService.hasAccess;
      if (!await hasAccess) {
        throw Exception("Error [getAllAsset] failed to gain access");
      }
      final box = await Hive.openBox<HiveBackupAlbums>(hiveBackupInfoBox);
      final HiveBackupAlbums? backupAlbumInfo = box.get(backupInfoKey);
      if (backupAlbumInfo != null) {
        return (await _backupService
            .buildUploadCandidates(backupAlbumInfo.deepCopy()));
      }
    } catch (e) {
      debugPrint("Error [_getLocalAssets] ${e.toString()}");
    }
    return null;
  }

  Future<bool> fetchLocalAssets() async {
    final Stopwatch sw = Stopwatch()..start();
    final int c = await _db.assets.where().localIdIsNotNull().count();
    final List<AssetEntity>? entities = await getLocalAssets(urgent: c == 0);
    if (entities == null) {
      debugPrint("fetchLocalAssets fast took ${sw.elapsedMilliseconds}ms");
      return false;
    }

    final HashSet<String> existingLocalIds = HashSet.from(
      await _db.assets.where().localIdIsNotNull().localIdProperty().findAll(),
    );
    final Id loggedInUserId = await _db.values.getInt(DbKey.loggedInUser);
    final User? loggedInUser = await _db.users.get(loggedInUserId);

    final List<Asset> assets = entities
        .where((e) => !existingLocalIds.contains(e.id))
        .map((e) => Asset.local(e, loggedInUser!))
        .toList(growable: false);

    // TODO figure out how to find deleted assets

    if (assets.isEmpty) {
      debugPrint("fetchLocalAssets medium ${sw.elapsedMilliseconds}ms");
      return false;
    }

    await _db.writeTxn(() async {
      await _db.assets.putAll(assets);
      await Future.wait(assets.map((e) => e.owner.save()));
    });
    final result = await _db.assets.where().findAll();
    assert(result.length >= assets.length);
    debugPrint("fetchLocalAssets full took ${sw.elapsedMilliseconds}ms");
    return true;
  }

  Future<Asset?> getAssetById(String assetId) async {
    try {
      return Asset.remote(await _apiService.assetApi.getAssetById(assetId));
    } catch (e) {
      debugPrint("Error [getAssetById]  ${e.toString()}");
      return null;
    }
  }

  Future<List<DeleteAssetResponseDto>?> deleteAssets(
    Iterable<AssetResponseDto> deleteAssets,
  ) async {
    try {
      final List<String> payload = [];

      for (final asset in deleteAssets) {
        payload.add(asset.id);
      }

      return await _apiService.assetApi
          .deleteAsset(DeleteAssetDto(ids: payload));
    } catch (e) {
      debugPrint("Error getAllAsset  ${e.toString()}");
      return null;
    }
  }
}
