import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/modules/album/services/album.service.dart';
import 'package:immich_mobile/shared/models/album.dart';
import 'package:immich_mobile/shared/models/asset.dart';
import 'package:immich_mobile/shared/providers/db.provider.dart';
import 'package:isar/isar.dart';

class AlbumNotifier extends StateNotifier<List<Album>> {
  AlbumNotifier(this._albumService, this._db) : super([]);
  final AlbumService _albumService;
  final Isar _db;

  getAllAlbums() async {
    if (0 < await _db.albums.count() && state.isEmpty) {
      state = await _db.albums.where().findAll();
    }

    if ((await Future.wait([
      _albumService.refreshDeviceAlbums(),
      _albumService.refreshRemoteAlbums(isShared: false)
    ]))
        .any((e) => e)) {
      state = await _db.albums.where().findAll();
    }
  }

  deleteAlbum(Album albumId) async {
    state = state.where((album) => album.id != albumId.id).toList();
    await _db.writeTxn(() async => _db.albums.delete(albumId.id));
  }

  Future<Album?> createAlbum(
    String albumTitle,
    Set<Asset> assets,
  ) async {
    Album? album = await _albumService.createAlbum(albumTitle, assets, []);

    if (album != null) {
      state = [...state, album];
      return album;
    }
    return null;
  }
}

final albumProvider = StateNotifierProvider<AlbumNotifier, List<Album>>((ref) {
  return AlbumNotifier(
    ref.watch(albumServiceProvider),
    ref.watch(dbProvider),
  );
});
