import 'package:hive/hive.dart';
import 'package:immich_mobile/constants/hive_box.dart';
import 'package:immich_mobile/shared/models/user.dart';
import 'package:isar/isar.dart';
import 'package:openapi/api.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:immich_mobile/utils/builtin_extensions.dart';

part 'asset.g.dart';

/// Asset (online or local)
@Collection()
class Asset {
  Asset.remote(AssetResponseDto? remote)
      : remoteId = remote!.id,
        createdAt = DateTime.parse(remote.createdAt),
        modifiedAt = DateTime.parse(remote.modifiedAt),
        durationInSeconds = remote.duration.toDuration().inSeconds,
        height = remote.exifInfo?.exifImageHeight?.toInt(),
        width = remote.exifInfo?.exifImageWidth?.toInt(),
        name = remote.exifInfo?.imageName,
        deviceId = remote.deviceId,
        _tempOwnerId = remote.ownerId,
        latitude = remote.exifInfo?.latitude?.toDouble(),
        longitude = remote.exifInfo?.longitude?.toDouble();

  Asset.local(AssetEntity? local, User? owner)
      : localId = local!.id,
        latitude = local.latitude,
        longitude = local.longitude,
        durationInSeconds = local.duration,
        height = local.height,
        width = local.width,
        name = local.title,
        deviceId = Hive.box(userInfoBox).get(deviceIdKey),
        modifiedAt = local.modifiedDateTime,
        createdAt = local.createDateTime {
    this.owner.value = owner;
  }

  Asset(
    this.id,
    this.createdAt,
    this.durationInSeconds,
    this.modifiedAt,
    this.deviceId,
  );

  @ignore
  AssetResponseDto? get remote {
    if (isRemote && _remote == null) {
      final ownerId = owner.value?.id ?? _tempOwnerId;
      _remote = AssetResponseDto(
        type: isImage ? AssetTypeEnum.IMAGE : AssetTypeEnum.VIDEO,
        id: remoteId!,
        deviceAssetId: deviceAssetId,
        ownerId: ownerId!,
        deviceId: deviceId,
        originalPath: 'upload/$ownerId}/original/$deviceId/$remoteId.jpg',
        resizePath: 'upload/$ownerId/thumb/$deviceId/$remoteId.jpeg',
        createdAt: createdAt.toIso8601String(),
        modifiedAt: modifiedAt.toIso8601String(),
        isFavorite: false,
        mimeType: '',
        duration: duration.toString(),
        webpPath: 'upload/$ownerId/original/$deviceId/$remoteId.webp',
      );
    }
    return _remote;
  }

  @ignore
  AssetEntity? get local {
    if (isLocal && _local == null) {
      _local = AssetEntity(
        id: localId!,
        typeInt: isImage ? 1 : 2,
        width: width!,
        height: height!,
        duration: durationInSeconds,
        createDateSecond: createdAt.millisecondsSinceEpoch ~/ 1000,
        latitude: latitude,
        longitude: longitude,
        modifiedDateSecond: modifiedAt.millisecondsSinceEpoch ~/ 1000,
        title: name,
      );
    }
    return _local;
  }

  @ignore
  AssetResponseDto? _remote;

  @ignore
  AssetEntity? _local;

  @ignore
  String? _tempOwnerId;

  Id id = Isar.autoIncrement;

  @Index(unique: false, replace: false, type: IndexType.hash)
  String? remoteId;

  @Index(unique: false, replace: false, type: IndexType.hash)
  String? localId;

  String deviceId;

  DateTime createdAt;

  DateTime modifiedAt;

  double? latitude;

  double? longitude;

  int durationInSeconds;

  int? width;

  int? height;

  String? name;

  final IsarLink<User> owner = IsarLink<User>();

  // convenince getters:

  @ignore
  bool get isRemote => remoteId != null;
  @ignore
  bool get isLocal => localId != null;

  @ignore
  String get deviceAssetId => localId ?? '';

  @ignore
  bool get isImage => durationInSeconds == 0;

  @ignore
  Duration get duration => Duration(seconds: durationInSeconds);

  @override
  bool operator ==(other) {
    if (other is! Asset) return false;
    return id == other.id;
  }

  @override
  @ignore
  int get hashCode => id.hashCode;
}

extension AssetsHelper on IsarCollection<Asset> {
  Future<int> deleteAllByRemoteId(Iterable<String> ids) =>
      ids.isEmpty ? Future.value(0) : _remote(ids).deleteAll();
  Future<int> deleteAllByLocalId(Iterable<String> ids) =>
      ids.isEmpty ? Future.value(0) : _local(ids).deleteAll();
  Future<List<Asset>> getAllByRemoteId(Iterable<String> ids) =>
      ids.isEmpty ? Future.value([]) : _remote(ids).findAll();
  Future<List<Asset>> getAllByLocalId(Iterable<String> ids) =>
      ids.isEmpty ? Future.value([]) : _local(ids).findAll();

  QueryBuilder<Asset, Asset, QAfterWhereClause> _remote(Iterable<String> ids) =>
      where().anyOf(ids, (q, String e) => q.remoteIdEqualTo(e));
  QueryBuilder<Asset, Asset, QAfterWhereClause> _local(Iterable<String> ids) =>
      where().anyOf(ids, (q, String e) => q.localIdEqualTo(e));
}
