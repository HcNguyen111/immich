import 'dart:collection';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/shared/services/asset.service.dart';
import 'package:immich_mobile/shared/models/asset.dart';
import 'package:immich_mobile/shared/models/user.dart';
import 'package:immich_mobile/shared/providers/db.provider.dart';
import 'package:immich_mobile/shared/services/device_info.service.dart';
import 'package:collection/collection.dart';
import 'package:immich_mobile/shared/services/user.service.dart';
import 'package:intl/intl.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';
import 'package:photo_manager/photo_manager.dart';

class AssetNotifier extends StateNotifier<List<Asset>> {
  final AssetService _assetService;
  final UserService _userService;
  final Isar _db;
  final log = Logger('AssetNotifier');
  final DeviceInfoService _deviceInfoService = DeviceInfoService();
  bool _getAllAssetInProgress = false;
  bool _deleteInProgress = false;

  AssetNotifier(this._assetService, this._userService, this._db) : super([]);

  Future<void> _fetchAllUsers() async {
    final dtos = await _userService.getAllUsersInfo(isAll: true);
    if (dtos == null) {
      return;
    }
    final HashSet<String> existingUsers = HashSet.from(
      await _db.users.where().idProperty().findAll(),
    );
    final HashSet<String> currentUsers = HashSet.from(
      dtos.map((e) => e.id),
    );
    final List<String> deletedUsers =
        existingUsers.difference(currentUsers).toList(growable: false);
    final users = dtos.map((e) => User.fromDto(e)).toList(growable: false);
    await _db.writeTxn(() async {
      // note: cannot clearAll and putAll because this invalidates the links from Asset/Ablum to User
      await _db.users.deleteAllById(deletedUsers);
      await _db.users.putAll(users);
    });
  }

  getAllAsset() async {
    if (_getAllAssetInProgress || _deleteInProgress) {
      // guard against multiple calls to this method while it's still working
      return;
    }
    final stopwatch = Stopwatch();
    try {
      _getAllAssetInProgress = true;
      // await clearAllAsset();
      await _fetchAllUsers();
      final int cachedCount = await _db.assets.count();
      stopwatch.start();
      // final bool isCacheValid = await _assetCacheService.isValid();
      final localTask = _assetService.fetchLocalAssets();
      final remoteTask = _assetService.fetchRemoteAssets();
      if (cachedCount > 0 && state.isEmpty || cachedCount != state.length) {
        // state = await _assetCacheService.get();
        state = await _db.assets.where().findAll();
        log.info(
          "Reading assets from cache: ${stopwatch.elapsedMilliseconds}ms",
        );
        stopwatch.reset();
      }
      final bool newRemote = await remoteTask;
      final bool newLocal = await localTask;
      log.info("Load assets: ${stopwatch.elapsedMilliseconds}ms");
      stopwatch.reset();
      if (!newRemote && !newLocal) {
        log.info("state is already up-to-date");
        return;
      }
      stopwatch.reset();
      final assets = await _db.assets.where().findAll();
      log.info("setting new asset state");
      state = assets;
    } finally {
      _getAllAssetInProgress = false;
    }
  }

  Future<void> clearAllAsset() {
    state = [];
    // _cacheState();
    return _db.writeTxn(() async => _db.assets.clear());
  }

  Future<void> onNewAssetUploaded(AssetResponseDto newAsset) {
    final int i = state.indexWhere(
      (a) =>
          a.isRemote ||
          (a.localId == newAsset.deviceAssetId &&
              a.deviceId == newAsset.deviceId),
    );

    final Asset a = Asset.remote(newAsset);
    if (i == -1 || state[i].deviceAssetId != newAsset.deviceAssetId) {
      state = [...state, a];
    } else {
      // order is important to keep all local-only assets at the beginning!
      state = [
        ...state.slice(0, i),
        ...state.slice(i + 1),
        a,
      ];
      _db.assets.put(a);
      // TODO here is a place to unify local/remote assets by replacing the
      // local-only asset in the state with a local&remote asset
    }
    return _db.writeTxn(() async => await _db.assets.put(a));
    // _cacheState();
  }

  deleteAssets(Set<Asset> deleteAssets) async {
    _deleteInProgress = true;
    try {
      final localDeleted = await _deleteLocalAssets(deleteAssets);
      final remoteDeleted = await _deleteRemoteAssets(deleteAssets);
      final Set<String> deleted = HashSet();
      deleted.addAll(localDeleted);
      deleted.addAll(remoteDeleted);
      if (deleted.isNotEmpty) {
        state = state
            .where(
              (a) => !deleted.contains(a.isLocal ? a.localId! : a.remoteId!),
            )
            .toList();
        await _db.writeTxn(() async {
          await _db.assets.deleteAllByLocalId(localDeleted);
          await _db.assets.deleteAllByRemoteId(remoteDeleted);
        });
        // _cacheState();
      }
    } finally {
      _deleteInProgress = false;
    }
  }

  Future<List<String>> _deleteLocalAssets(Set<Asset> assetsToDelete) async {
    var deviceInfo = await _deviceInfoService.getDeviceInfo();
    var deviceId = deviceInfo["deviceId"];
    final List<String> local = [];
    // Delete asset from device
    for (final Asset asset in assetsToDelete) {
      if (asset.isLocal) {
        local.add(asset.localId!);
      } else if (asset.deviceId == deviceId) {
        // Delete asset on device if it is still present
        var localAsset = await AssetEntity.fromId(asset.deviceAssetId);
        if (localAsset != null) {
          local.add(localAsset.id);
        }
      }
    }
    if (local.isNotEmpty) {
      try {
        return await PhotoManager.editor.deleteWithIds(local);
      } catch (e, stack) {
        log.severe("Failed to delete asset from device", e, stack);
      }
    }
    return [];
  }

  Future<List<String>> _deleteRemoteAssets(
    Set<Asset> assetsToDelete,
  ) async {
    final Iterable<AssetResponseDto> remote =
        assetsToDelete.where((e) => e.isRemote).map((e) => e.remote!);
    final List<DeleteAssetResponseDto> deleteAssetResult =
        await _assetService.deleteAssets(remote) ?? [];
    return deleteAssetResult
        .where((a) => a.status == DeleteAssetStatus.SUCCESS)
        .map((a) => a.id)
        .toList(growable: false);
  }
}

final assetProvider = StateNotifierProvider<AssetNotifier, List<Asset>>((ref) {
  return AssetNotifier(
    ref.watch(assetServiceProvider),
    ref.watch(userServiceProvider),
    ref.watch(dbProvider),
  );
});

final assetGroupByDateTimeProvider = StateProvider((ref) {
  final assets = ref.watch(assetProvider).toList();
  // `toList()` ist needed to make a copy as to NOT sort the original list/state

  assets.sortByCompare<DateTime>(
    (e) => e.createdAt,
    (a, b) => b.compareTo(a),
  );
  return assets.groupListsBy(
    (element) => DateFormat('y-MM-dd').format(element.createdAt.toLocal()),
  );
});

final assetGroupByMonthYearProvider = StateProvider((ref) {
  // TODO: remove `where` once temporary workaround is no longer needed (to only
  // allow remote assets to be added to album). Keep `toList()` as to NOT sort
  // the original list/state
  final assets = ref.watch(assetProvider).where((e) => e.isRemote).toList();

  assets.sortByCompare<DateTime>(
    (e) => e.createdAt,
    (a, b) => b.compareTo(a),
  );

  return assets.groupListsBy(
    (element) => DateFormat('MMMM, y').format(element.createdAt.toLocal()),
  );
});
