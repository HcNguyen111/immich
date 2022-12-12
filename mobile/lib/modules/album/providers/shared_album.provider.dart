import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/modules/album/services/album.service.dart';
import 'package:immich_mobile/shared/models/album.dart';
import 'package:immich_mobile/shared/models/asset.dart';
import 'package:immich_mobile/shared/providers/db.provider.dart';
import 'package:isar/isar.dart';

class SharedAlbumNotifier extends StateNotifier<List<Album>> {
  SharedAlbumNotifier(
    this._sharedAlbumService,
    this._db,
  ) : super([]);

  final AlbumService _sharedAlbumService;
  final Isar _db;

  // _cacheState() {
  //   _sharedAlbumCacheService.put(state);
  // }

  Future<Album?> createSharedAlbum(
    String albumName,
    Set<Asset> assets,
    List<String> sharedUserIds,
  ) async {
    try {
      Album? newAlbum = await _sharedAlbumService.createAlbum(
        albumName,
        assets,
        sharedUserIds,
      );

      if (newAlbum != null) {
        state = [...state, newAlbum];
        // _cacheState();
        return newAlbum;
      }
    } catch (e) {
      debugPrint("Error createSharedAlbum  ${e.toString()}");
    }
    return null;
  }

  getAllSharedAlbums() async {
    if (0 < await _db.albums.filter().sharedEqualTo(true).count() &&
        state.isEmpty) {
      // state = await _sharedAlbumCacheService.get();
      state = await _db.albums.filter().sharedEqualTo(true).findAll();
    }

    _sharedAlbumService.refreshDeviceAlbums();

    if (await _sharedAlbumService.refreshRemoteAlbums(isShared: true)) {
      state = await _db.albums.filter().sharedEqualTo(true).findAll();
    }
  }

  deleteAlbum(Album albumId) async {
    state = state.where((album) => album.id != albumId.id).toList();
    await _db.writeTxn(() async => _db.albums.delete(albumId.id));
    // _cacheState();
  }

  Future<bool> leaveAlbum(Album albumId) async {
    var res = await _sharedAlbumService.leaveAlbum(albumId.remoteId!);

    if (res) {
      await deleteAlbum(albumId);
      return true;
    } else {
      return false;
    }
  }

  Future<bool> removeAssetFromAlbum(
    String albumId,
    Iterable<Asset> assetIds,
  ) async {
    var res = await _sharedAlbumService.removeAssetFromAlbum(
      albumId,
      assetIds.map((e) => e.remoteId!).toList(growable: false),
    );
    // TODO delete in local DB

    if (res) {
      return true;
    } else {
      return false;
    }
  }
}

final sharedAlbumProvider =
    StateNotifierProvider<SharedAlbumNotifier, List<Album>>((ref) {
  return SharedAlbumNotifier(
    ref.watch(albumServiceProvider),
    ref.watch(dbProvider),
  );
});

final sharedAlbumDetailProvider =
    FutureProvider.autoDispose.family<Album?, int>((ref, albumId) async {
  final AlbumService sharedAlbumService = ref.watch(albumServiceProvider);

  return await sharedAlbumService.getAlbumDetail(albumId);
});
