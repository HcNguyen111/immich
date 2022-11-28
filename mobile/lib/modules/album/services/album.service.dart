import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/hive_box.dart';
import 'package:immich_mobile/modules/backup/models/hive_backup_albums.model.dart';
import 'package:immich_mobile/shared/models/album.dart';
import 'package:immich_mobile/shared/models/asset.dart';
import 'package:immich_mobile/shared/models/user.dart';
import 'package:immich_mobile/shared/models/value.dart';
import 'package:immich_mobile/shared/providers/api.provider.dart';
import 'package:immich_mobile/shared/providers/db.provider.dart';
import 'package:immich_mobile/shared/services/api.service.dart';
import 'package:immich_mobile/utils/diff.dart';
import 'package:isar/isar.dart';
import 'package:openapi/api.dart';
import 'package:photo_manager/photo_manager.dart';

final albumServiceProvider = Provider(
  (ref) => AlbumService(
    ref.watch(apiServiceProvider),
    ref.watch(dbProvider),
  ),
);

class AlbumService {
  final ApiService _apiService;
  final Isar _db;

  AlbumService(this._apiService, this._db);

  Future<bool> refreshDeviceAlbums() async {
    final List<AssetPathEntity> onDevice = await PhotoManager.getAssetPathList(
      hasAll: false,
      filterOption: FilterOptionGroup(containsPathModified: true),
    );
    HiveBackupAlbums? infos =
        Hive.box<HiveBackupAlbums>(hiveBackupInfoBox).get(backupInfoKey);
    if (infos == null) {
      return false;
    }
    if (infos.excludedAlbumsIds.isNotEmpty) {
      onDevice.removeWhere((e) => infos.excludedAlbumsIds.contains(e.id));
    }
    if (infos.selectedAlbumIds.isNotEmpty) {
      onDevice.removeWhere((e) => !infos.selectedAlbumIds.contains(e.id));
    }
    onDevice.sort(
      (a, b) => a.id.compareTo(b.id),
    );

    final List<Album> inDb =
        await _db.albums.where().localIdIsNotNull().sortByLocalId().findAll();
    return diffSortedLists(
      onDevice,
      inDb,
      compare: (AssetPathEntity a, Album b) => a.id.compareTo(b.localId!),
      both: _syncAlbumInDbAndOnDevice,
      onlyFirst: _addAlbumFromDevice,
      onlySecond: _removeAlbumFromDb,
    );
  }

  Future<bool> _syncAlbumInDbAndOnDevice(
      AssetPathEntity ape, Album album) async {
    if (await _hasAssetPathEntityChanged(ape, album)) {
      final int totalOnDevice = await ape.assetCountAsync;
      AssetPathEntity? modified = await ape.fetchPathProperties(
        filterOptionGroup: FilterOptionGroup(
          containsPathModified: true,
          updateTimeCond: DateTimeCond(
            min: album.modifiedAt,
            max: DateTime.now(),
          ),
        ),
      );
      if (modified == null) {
        debugPrint("[_syncAlbumInDbAndOnDevice] modified==null");
        return false;
      }
      final List<AssetEntity> newAssets = await modified.getAssetListRange(
        start: 0,
        end: 0x7fffffffffffffff,
      );
      if (totalOnDevice == album.assetCount + newAssets.length) {
        // fast path for common case: add new assets to album
        final List<Asset> assetsToAdd = newAssets
            .map((e) => Asset.local(e, album.owner.value))
            .toList(growable: false);
        await _db.writeTxn(() async {
          await _db.assets.putAll(assetsToAdd);
          album.assets.addAll(assetsToAdd);
          await album.assets.save();
        });
      } else {
        // general case, e.g. some assets have been deleted
        await album.assets.load();
        // put this in AssetService?
        final List<Asset> inDb = album.assets.toList(growable: false);
        inDb.sort((a, b) => a.localId!.compareTo(b.localId!));
        List<AssetEntity> onDevice =
            await ape.getAssetListRange(start: 0, end: totalOnDevice);
        onDevice.sort((a, b) => a.id.compareTo(b.id));
        final List<Asset> toAdd = [];
        final List<Asset> toDelete = [];
        diffSortedLists(
          onDevice,
          inDb,
          compare: (AssetEntity a, Asset b) => a.id.compareTo(b.localId!),
          both: (a, b) => Future.value(false),
          onlyFirst: (AssetEntity a) =>
              toAdd.add(Asset.local(a, album.owner.value)),
          onlySecond: (Asset b) => toDelete.add(b),
        );
        album.assets.removeAll(toDelete);
        album.assets.addAll(toAdd);
        await _db.writeTxn(() async {
          await _db.assets.putAll(toAdd);
          await album.assets.save();
          // TODO delete assets in DB unless they are now part of some other album
        });
      }

      album.name = ape.name;
      album.assetCount = totalOnDevice;
      album.modifiedAt = ape.lastModified!;
      return true;
    }
    return false;
  }

  void _addAlbumFromDevice(AssetPathEntity ape) async {
    final Album newAlbum = Album(
      null,
      ape.name,
      ape.lastModified!,
      ape.lastModified!,
      await ape.assetCountAsync,
      false,
    );
    newAlbum.localId = ape.id;
    newAlbum.owner.value =
        await _db.users.get(await _db.values.getInt(DbKey.loggedInUser));

    // put the following into AssetService?
    final List<AssetEntity> deviceAssets =
        await ape.getAssetListRange(start: 0, end: newAlbum.assetCount);
    final List<String> dbAssets = (await _db.assets
            .where()
            .anyOf(deviceAssets, (q, AssetEntity e) => q.localIdEqualTo(e.id))
            .sortByLocalId()
            .localIdProperty()
            .findAll())
        .cast<String>();

    final List<Asset> toAdd = [];
    final List<String> toDeleteIds = [];
    final List<String> toLinkIds = [];
    diffSortedLists(
      deviceAssets,
      dbAssets,
      compare: (AssetEntity a, String b) => a.id.compareTo(b),
      both: (AssetEntity a, String b) {
        toLinkIds.add(b);
        return Future.value(true);
      },
      onlyFirst: (AssetEntity a) =>
          toAdd.add(Asset.local(a, newAlbum.owner.value)),
      onlySecond: (String b) => toDeleteIds.add(b),
    );
    if (toLinkIds.isNotEmpty) {
      final List<Asset> toLink = await _db.assets.getAllByLocalId(toLinkIds);
      newAlbum.assets.addAll(toLink);
    }
    newAlbum.assets.addAll(toAdd);
    await _db.writeTxn(() async {
      await _db.assets.putAll(toAdd);
      await Future.wait(toAdd.map((e) => e.owner.save()));
      await _db.albums.put(newAlbum);
      await newAlbum.owner.save();
      await newAlbum.assets.save();
    });

    newAlbum.albumThumbnailAsset.value = newAlbum.assets.first;
    await _db.writeTxn(() => newAlbum.albumThumbnailAsset.save());
    // TODO delete assets in DB unless they are now part of some other album
  }

  void _removeAlbumFromDb(Album album) async {
    await _db.writeTxn(() async => _db.albums.delete(album.id));
    // TODO delete assets in DB (if device album) unless they are now part of some other album
  }

  Future<bool> refreshRemoteAlbums({required bool isShared}) async {
    // TODO implement
    List<AlbumResponseDto>? serverAlbums =
        await getAlbums(isShared: isShared, details: true);
    if (serverAlbums == null) {
      return false;
    }
    serverAlbums.sort((a, b) => a.id.compareTo(b.id));
    final List<Album> dbAlbums =
        await _db.albums.where().remoteIdIsNotNull().sortByRemoteId().findAll();
    return diffSortedLists(
      serverAlbums,
      dbAlbums,
      compare: (AlbumResponseDto a, Album b) => a.id.compareTo(b.remoteId!),
      both: _syncAlbumInDbAndOnServer,
      onlyFirst: _addAlbumFromServer,
      onlySecond: _removeAlbumFromDb,
    );
  }

  Future<bool> _syncAlbumInDbAndOnServer(
    AlbumResponseDto dto,
    Album album,
  ) async {
    final modifiedOnServer = DateTime.parse(dto.modifiedAt).toUtc();
    if (dto.assetCount == album.assetCount &&
        dto.albumName == album.name &&
        dto.albumThumbnailAssetId ==
            album.albumThumbnailAsset.value?.remoteId &&
        dto.shared == album.shared &&
        modifiedOnServer == album.modifiedAt.toUtc()) {
      return false;
    }
    dto.assets.sort((a, b) => a.id.compareTo(b.id));
    await album.assets.load();
    final assetsInDb =
        album.assets.where((e) => e.isRemote).toList(growable: false);
    assetsInDb.sort((a, b) => a.remoteId!.compareTo(b.remoteId!));
    final List<String> idsToAdd = [];
    final List<Asset> toUnlink = [];
    await diffSortedLists(
      dto.assets,
      assetsInDb,
      compare: (AssetResponseDto a, Asset b) => a.id.compareTo(b.remoteId!),
      both: (a, b) => Future.value(false),
      onlyFirst: (AssetResponseDto a) => idsToAdd.add(a.id),
      onlySecond: (Asset a) => toUnlink.add(a),
    );

    // update shared users
    List<User> sharedUsers = album.sharedUsers.toList(growable: false);
    sharedUsers.sort((a, b) => a.id.compareTo(b.id));
    dto.sharedUsers.sort((a, b) => a.id.compareTo(b.id));
    List<String> userIdsToAdd = [];
    List<User> usersToUnlink = [];
    await diffSortedLists(
      dto.sharedUsers,
      sharedUsers,
      compare: (UserResponseDto a, User b) => a.id.compareTo(b.id),
      both: (a, b) => Future.value(false),
      onlyFirst: (UserResponseDto a) => userIdsToAdd.add(a.id),
      onlySecond: (User a) => usersToUnlink.add(a),
    );

    // if (idsToAdd.isEmpty &&
    //     toUnlink.isEmpty &&
    //     album.name == dto.albumName &&
    //     album.shared == dto.shared &&
    //     album.sharedUsers.length == dto.sharedUsers.length &&
    //     userIdsToAdd.isEmpty &&
    //     usersToUnlink.isEmpty) {
    //   return false;
    // }

    album.name = dto.albumName;
    album.shared = dto.shared;
    album.modifiedAt = modifiedOnServer;
    album.assetCount = dto.assetCount;
    if (album.albumThumbnailAsset.value?.remoteId !=
        dto.albumThumbnailAssetId) {
      album.albumThumbnailAsset.value = await _db.assets
          .where()
          .remoteIdEqualTo(dto.albumThumbnailAssetId)
          .findFirst();
    }
    final assetsToLink = await _db.assets.getAllByRemoteId(idsToAdd);
    List<User> usersToLink = (await _db.users.getAllById(userIdsToAdd)).cast();

    // write & commit all changes to DB
    await _db.writeTxn(() async {
      await _db.albums.put(album);
      await album.albumThumbnailAsset.save();
      await album.sharedUsers.update(link: usersToLink, unlink: usersToUnlink);
      await album.assets.update(link: assetsToLink, unlink: toUnlink.cast());
    });

    return true;
  }

  void _addAlbumFromServer(AlbumResponseDto dto) async {
    Album a = await Album.fromDto(dto, _db);
    await a.storeToDb(_db);
  }

  Future<List<AlbumResponseDto>?> getAlbums({
    required bool isShared,
    bool details = false,
  }) async {
    try {
      return await _apiService.albumApi.getAllAlbums(
        shared: isShared ? isShared : null,
        details: details ? details : null,
      );
    } catch (e) {
      debugPrint("Error getAllSharedAlbum  ${e.toString()}");
      return null;
    }
  }

  Future<Album?> createAlbum(
    String albumName,
    Iterable<Asset> assets,
    List<String> sharedUserIds,
  ) async {
    try {
      AlbumResponseDto? remote = await _apiService.albumApi.createAlbum(
        CreateAlbumDto(
          albumName: albumName,
          assetIds: assets.map((asset) => asset.remoteId!).toList(),
          sharedWithUserIds: sharedUserIds,
        ),
      );
      if (remote != null) {
        Album album = await Album.fromDto(remote, _db);
        album.storeToDb(_db);
        return album;
      }
    } catch (e) {
      debugPrint("Error createSharedAlbum  ${e.toString()}");
    }
    return null;
  }

  /*
   * Creates names like Untitled, Untitled (1), Untitled (2), ...
   */
  Future<String> _getNextAlbumName() async {
    const baseName = "Untitled";
    for (int round = 0;; round++) {
      final proposedName = "$baseName${round == 0 ? "" : " ($round)"}";

      if (null ==
          await _db.albums.filter().nameEqualTo(proposedName).findFirst()) {
        return proposedName;
      }
    }
  }

  Future<Album?> createAlbumWithGeneratedName(
    Iterable<Asset> assets,
  ) async {
    return createAlbum(
      await _getNextAlbumName(),
      assets,
      [],
    );
  }

  Future<Album?> getAlbumDetail(int albumId) {
    // try {
    //   return await _apiService.albumApi.getAlbumInfo(albumId);
    // } catch (e) {
    //   debugPrint('Error [getAlbumDetail] ${e.toString()}');
    //   return null;
    // }
    return _db.albums.get(albumId);
  }

  Future<AddAssetsResponseDto?> addAdditionalAssetToAlbum(
    Iterable<Asset> assets,
    Album albumId,
  ) async {
    try {
      var result = await _apiService.albumApi.addAssetsToAlbum(
        albumId.remoteId!,
        AddAssetsDto(assetIds: assets.map((asset) => asset.remoteId!).toList()),
      );
      return result;
    } catch (e) {
      debugPrint("Error addAdditionalAssetToAlbum  ${e.toString()}");
      return null;
    }
  }

  Future<bool> addAdditionalUserToAlbum(
    List<String> sharedUserIds,
    Album albumId,
  ) async {
    try {
      final result = await _apiService.albumApi.addUsersToAlbum(
        albumId.remoteId!,
        AddUsersDto(sharedUserIds: sharedUserIds),
      );
      if (result != null) {
        albumId.sharedUsers
            .addAll((await _db.users.getAllById(sharedUserIds)).cast());
        await _db.writeTxn(() => albumId.sharedUsers.save());
        return true;
      }
    } catch (e) {
      debugPrint("Error addAdditionalUserToAlbum  ${e.toString()}");
    }
    return false;
  }

  Future<bool> deleteAlbum(Album album) async {
    try {
      await _apiService.albumApi.deleteAlbum(album.remoteId!);
      return true;
    } catch (e) {
      debugPrint("Error deleteAlbum  ${e.toString()}");
    }
    return false;
  }

  Future<bool> leaveAlbum(String albumId) async {
    try {
      await _apiService.albumApi.removeUserFromAlbum(albumId, "me");

      return true;
    } catch (e) {
      debugPrint("Error deleteAlbum  ${e.toString()}");
      return false;
    }
  }

  Future<bool> removeAssetFromAlbum(
    String albumId,
    List<String> assetIds,
  ) async {
    try {
      await _apiService.albumApi.removeAssetFromAlbum(
        albumId,
        RemoveAssetsDto(assetIds: assetIds),
      );

      return true;
    } catch (e) {
      debugPrint("Error deleteAlbum  ${e.toString()}");
      return false;
    }
  }

  Future<bool> changeTitleAlbum(
    String albumId,
    String ownerId,
    String newAlbumTitle,
  ) async {
    try {
      await _apiService.albumApi.updateAlbumInfo(
        albumId,
        UpdateAlbumDto(
          albumName: newAlbumTitle,
        ),
      );

      return true;
    } catch (e) {
      debugPrint("Error deleteAlbum  ${e.toString()}");
      return false;
    }
  }
}

Future<bool> _hasAssetPathEntityChanged(AssetPathEntity a, Album b) async {
  return a.name != b.name ||
      a.lastModified != b.modifiedAt ||
      await a.assetCountAsync != b.assets.length;
}
