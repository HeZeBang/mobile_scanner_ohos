/*
* Copyright (c) 2023 Shenzhen Kaihong Digital Industry Development Co., Ltd.
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import camera from '@ohos.multimedia.camera';
import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import image from '@ohos.multimedia.image';

/**
 * 如果获取对象失败，说明相机可能被占用或无法使用。如果被占用，须等到相机被释放后才能重新获取。
 * @param context
 * @returns
 */
export function getCameraManager(context: common.BaseContext): camera.CameraManager {
  let cameraManager: camera.CameraManager = camera.getCameraManager(context);
  return cameraManager;
}

/**
 * 通过cameraManager类中的getSupportedCameras()方法，获取当前设备支持的相机列表，列表中存储了设备支持的所有相机ID。
 * 若列表不为空，则说明列表中的每个ID都支持独立创建相机对象；否则，说明当前设备无可用相机，不可继续后续操作。
 * @param cameraManager
 * @returns
 */
export function getCameraDevices(cameraManager: camera.CameraManager): Array<camera.CameraDevice> {
  let cameraArray: Array<camera.CameraDevice> = cameraManager.getSupportedCameras();
  if (cameraArray != undefined && cameraArray.length <= 0) {
    console.error("[camera test] cameraManager.getSupportedCameras error");
    return [];
  }
  for (let index = 0; index < cameraArray.length; index++) {
    console.info('[camera test] cameraId : ' + cameraArray[index].cameraId); // 获取相机ID
    console.info('[camera test] cameraPosition : ' + cameraArray[index].cameraPosition); // 获取相机位置
    console.info('[camera test] cameraType : ' + cameraArray[index].cameraType); // 获取相机类型
    console.info('[camera test] connectionType : ' + cameraArray[index].connectionType); // 获取相机连接类型
  }
  return cameraArray;
}

/**
 * 调用cameraManager类中的createCaptureSession()方法创建一个会话
 * @param cameraManager
 * @returns
 */
export function getCaptureSession(cameraManager: camera.CameraManager): camera.CaptureSession | undefined {
  let captureSession: camera.CaptureSession | undefined = undefined;
  try {
    captureSession = cameraManager.createCaptureSession();
  } catch (error) {
    let err = error as BusinessError;
    console.error(`[camera test] Failed to create the CaptureSession instance. error: ${JSON.stringify(err)}`);
  }
  return captureSession;
}

/**
 * 调用captureSession类中的beginConfig()方法配置会话
 * @param captureSession
 */
export function beginConfig(captureSession: camera.CaptureSession): void {
  try {
    captureSession.beginConfig();
  } catch (error) {
    let err = error as BusinessError;
    console.error(`[camera test] Failed to beginConfig. error: ${JSON.stringify(err)}`);
  }
}

/**
 * 调用captureSession类中的commitConfig()和start()方法提交相关配置，并启动会话
 * @param captureSession
 * @returns
 */
export async function startSession(captureSession: camera.CaptureSession): Promise<void> {
  try {
    await captureSession.commitConfig();
  } catch (error) {
    let err = error as BusinessError;
    console.error(`[camera test] Failed to commitConfig. error: ${JSON.stringify(err)}`);
  }

  try {
    await captureSession.start()
  } catch (error) {
    let err = error as BusinessError;
    console.error(`[camera test] Failed to start. error: ${JSON.stringify(err)}`);
  }
}

export function getCameraInput(cameraDevice: camera.CameraDevice, cameraManager: camera.CameraManager): camera.CameraInput | null{
  // 创建相机输入流
  let cameraInput: camera.CameraInput | null = null;
  try {
    cameraInput = cameraManager.createCameraInput(cameraDevice);
    // 监听cameraInput错误信息
    cameraInput.on('error', cameraDevice, (error: BusinessError) => {
      console.info(`[camera test] Camera input error code: ${error.code}`);
    });
  } catch (error) {
    let err = error as BusinessError;
    console.error('[camera test] Failed to createCameraInput errorCode = ' + err.code);
  }

  return cameraInput;
}

/**
 * 通过getSupportedOutputCapability()方法，获取当前设备支持的所有输出流
 * 输出流在CameraOutputCapability中的各个profile字段中
 * @param cameraDevice
 * @param cameraManager
 * @returns
 */
export async function getSupportedOutputCapability(cameraDevice: camera.CameraDevice, cameraManager: camera.CameraManager,
                                                   cameraInput: camera.CameraInput): Promise<camera.CameraOutputCapability | undefined> {
  // 打开相机
  await cameraInput.open();
  // 获取相机设备支持的输出流能力
  let cameraOutputCapability = cameraManager.getSupportedOutputCapability(cameraDevice);
  if (!cameraOutputCapability) {
    console.error("[camera test] cameraManager.getSupportedOutputCapability error");
    return undefined;
  }
  console.info("[camera test] outputCapability: " + JSON.stringify(cameraOutputCapability));
  return cameraOutputCapability;
}

/**
 * 获取预览流
 * @param cameraManager
 * @param cameraOutputCapability
 * @param surfaceId
 * @returns
 */
export function getPreviewOutput(cameraManager: camera.CameraManager, cameraOutputCapability: camera.CameraOutputCapability,
                                 surfaceId: string): camera.PreviewOutput | undefined {
  let previewProfilesArray: Array<camera.Profile> = cameraOutputCapability.previewProfiles;
  let previewOutput: camera.PreviewOutput | undefined = undefined;
  try {
    previewOutput = cameraManager.createPreviewOutput(previewProfilesArray[0], surfaceId);
  } catch (error) {
    let err = error as BusinessError;
    console.error("[camera test] Failed to create the PreviewOutput instance. error code: " + err.code);
  }
  return previewOutput;
}

export function setSessionCameraInput(captureSession: camera.CaptureSession, cameraInput: camera.CameraInput): void{
  try {
    captureSession.addInput(cameraInput);
  } catch (error) {
    let err = error as BusinessError;
    console.error(`[camera test] Failed to addInput. error: ${JSON.stringify(err)}`);
  }
}

export function setSessionPreviewOutput(captureSession: camera.CaptureSession, previewOutput: camera.PreviewOutput): void{
  try {
    captureSession.addOutput(previewOutput);
  } catch (error) {
    let err = error as BusinessError;
    console.error(`[camera test] Failed to add previewOutput. error: ${JSON.stringify(err)}`);
  }
}
