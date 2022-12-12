import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/hive_box.dart';
import 'package:immich_mobile/modules/login/models/authentication_state.model.dart';
import 'package:immich_mobile/modules/login/models/hive_saved_login_info.model.dart';
import 'package:immich_mobile/modules/backup/services/backup.service.dart';
import 'package:immich_mobile/shared/models/album.dart';
import 'package:immich_mobile/shared/models/asset.dart';
import 'package:immich_mobile/shared/models/value.dart';
import 'package:immich_mobile/shared/models/user.dart';
import 'package:immich_mobile/shared/providers/api.provider.dart';
import 'package:immich_mobile/shared/providers/db.provider.dart';
import 'package:immich_mobile/shared/services/api.service.dart';
import 'package:immich_mobile/shared/services/device_info.service.dart';
import 'package:isar/isar.dart';
import 'package:openapi/api.dart';

class AuthenticationNotifier extends StateNotifier<AuthenticationState> {
  AuthenticationNotifier(
    this._deviceInfoService,
    this._backupService,
    this._apiService,
    this._db,
  ) : super(
          AuthenticationState(
            deviceId: "",
            deviceType: DeviceTypeEnum.ANDROID,
            userId: "",
            userEmail: "",
            firstName: '',
            lastName: '',
            profileImagePath: '',
            isAdmin: false,
            shouldChangePassword: false,
            isAuthenticated: false,
            deviceInfo: DeviceInfoResponseDto(
              id: 0,
              userId: "",
              deviceId: "",
              deviceType: DeviceTypeEnum.ANDROID,
              createdAt: "",
              isAutoBackup: false,
            ),
          ),
        );

  final DeviceInfoService _deviceInfoService;
  final BackupService _backupService;
  final ApiService _apiService;
  final Isar _db;

  Future<bool> login(
    String email,
    String password,
    String serverEndpoint,
    bool isSavedLoginInfo,
  ) async {
    // Store server endpoint to Hive and test endpoint
    if (serverEndpoint[serverEndpoint.length - 1] == "/") {
      var validUrl = serverEndpoint.substring(0, serverEndpoint.length - 1);
      Hive.box(userInfoBox).put(serverEndpointKey, validUrl);
    } else {
      Hive.box(userInfoBox).put(serverEndpointKey, serverEndpoint);
    }

    // Check Server URL validity
    try {
      _apiService.setEndpoint(Hive.box(userInfoBox).get(serverEndpointKey));
      await _apiService.serverInfoApi.pingServer();
    } catch (e) {
      debugPrint('Invalid Server Endpoint Url $e');
      return false;
    }

    // Make sign-in request
    try {
      var loginResponse = await _apiService.authenticationApi.login(
        LoginCredentialDto(
          email: email,
          password: password,
        ),
      );

      if (loginResponse == null) {
        debugPrint('Login Response is null');
        return false;
      }

      return setSuccessLoginInfo(
        accessToken: loginResponse.accessToken,
        serverUrl: serverEndpoint,
        isSavedLoginInfo: isSavedLoginInfo,
      );
    } catch (e) {
      HapticFeedback.vibrate();
      debugPrint("Error logging in $e");
      return false;
    }
  }

  Future<bool> logout() async {
    state = state.copyWith(isAuthenticated: false);
    await Future.wait([
      Hive.box(userInfoBox).delete(accessTokenKey),
      Hive.box(userInfoBox).delete(assetEtagKey),
      _db.assets.clear(),
      _db.albums.clear(),
      _db.users.clear(),
      _db.values.clear(),
    ]);

    // Remove login info from local storage
    var loginInfo =
        Hive.box<HiveSavedLoginInfo>(hiveLoginInfoBox).get(savedLoginInfoKey);
    if (loginInfo != null) {
      loginInfo.email = "";
      loginInfo.password = "";
      loginInfo.isSaveLogin = false;

      await Hive.box<HiveSavedLoginInfo>(hiveLoginInfoBox).put(
        savedLoginInfoKey,
        loginInfo,
      );
    }
    return true;
  }

  setAutoBackup(bool backupState) async {
    var deviceInfo = await _deviceInfoService.getDeviceInfo();
    var deviceId = deviceInfo["deviceId"];

    DeviceTypeEnum deviceType = deviceInfo["deviceType"];

    DeviceInfoResponseDto updatedDeviceInfo =
        await _backupService.setAutoBackup(backupState, deviceId, deviceType);

    state = state.copyWith(deviceInfo: updatedDeviceInfo);
  }

  updateUserProfileImagePath(String path) {
    state = state.copyWith(profileImagePath: path);
  }

  Future<bool> changePassword(String newPassword) async {
    try {
      await _apiService.userApi.updateUser(
        UpdateUserDto(
          id: state.userId,
          password: newPassword,
          shouldChangePassword: false,
        ),
      );

      state = state.copyWith(shouldChangePassword: false);

      return true;
    } catch (e) {
      debugPrint("Error changing password $e");
      return false;
    }
  }

  Future<bool> setSuccessLoginInfo({
    required String accessToken,
    required String serverUrl,
    required bool isSavedLoginInfo,
  }) async {
    _apiService.setAccessToken(accessToken);
    final Id loggedInUserId = await _db.values.getInt(DbKey.loggedInUser);
    final User? loggedInUser = await _db.users.get(loggedInUserId);
    UserResponseDto? userResponseDto;
    try {
      userResponseDto = await _apiService.userApi.getMyUserInfo();
    } catch (e) {
      if (e is ApiException &&
          e.code == HttpStatus.badRequest &&
          e.innerException is SocketException) {
        // offline? use cached info
        userResponseDto = loggedInUser?.toDto();
      }
    }

    if (userResponseDto != null) {
      final User user = User.fromDto(userResponseDto);
      if (user != loggedInUser) {
        await _db.writeTxn(() async {
          await _db.users.put(user);
          await _db.values.setInt(DbKey.loggedInUser, user.isarId);
        });
      }
      var deviceInfo = await _deviceInfoService.getDeviceInfo();
      final box = await Hive.openBox(userInfoBox);
      box.put(deviceIdKey, deviceInfo["deviceId"]);
      box.put(accessTokenKey, accessToken);
      box.put(serverEndpointKey, serverUrl);

      state = state.copyWith(
        isAuthenticated: true,
        userId: userResponseDto.id,
        userEmail: userResponseDto.email,
        firstName: userResponseDto.firstName,
        lastName: userResponseDto.lastName,
        profileImagePath: userResponseDto.profileImagePath,
        isAdmin: userResponseDto.isAdmin,
        shouldChangePassword: userResponseDto.shouldChangePassword,
        deviceId: deviceInfo["deviceId"],
        deviceType: deviceInfo["deviceType"],
      );

      if (isSavedLoginInfo) {
        // Save login info to local storage
        Hive.box<HiveSavedLoginInfo>(hiveLoginInfoBox).put(
          savedLoginInfoKey,
          HiveSavedLoginInfo(
            email: "",
            password: "",
            isSaveLogin: true,
            serverUrl: serverUrl,
            accessToken: accessToken,
          ),
        );
      } else {
        Hive.box<HiveSavedLoginInfo>(hiveLoginInfoBox)
            .delete(savedLoginInfoKey);
      }
    } else {
      return false;
    }

    // Register device info
    DeviceInfoResponseDto? deviceInfo;
    try {
      deviceInfo = await _apiService.deviceInfoApi.upsertDeviceInfo(
        UpsertDeviceInfoDto(
          deviceId: state.deviceId,
          deviceType: state.deviceType,
        ),
      );

      if (deviceInfo == null) {
        debugPrint('Device Info Response is null');
        return false;
      }
      final json = deviceInfo.toJson();
      await _db.writeTxn(() => _db.values.setJson(DbKey.deviceInfo, json));
    } catch (e) {
      if (e is ApiException &&
          e.code == HttpStatus.badRequest &&
          e.innerException is SocketException) {
        // offline? use cached info
        deviceInfo = await _db.values.getJson(DbKey.deviceInfo);
      }
      if (deviceInfo == null) {
        debugPrint("ERROR Register Device Info: $e");
        return false;
      }
    }
    state = state.copyWith(deviceInfo: deviceInfo);

    return true;
  }
}

final authenticationProvider =
    StateNotifierProvider<AuthenticationNotifier, AuthenticationState>((ref) {
  return AuthenticationNotifier(
    ref.watch(deviceInfoServiceProvider),
    ref.watch(backupServiceProvider),
    ref.watch(apiServiceProvider),
    ref.watch(dbProvider),
  );
});
