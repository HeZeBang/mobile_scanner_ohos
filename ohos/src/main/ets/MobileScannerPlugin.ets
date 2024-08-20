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

import {
  FlutterPlugin,
  FlutterPluginBinding
} from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodChannel, {
  MethodCallHandler,
  MethodResult
} from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import Log from '@ohos/flutter_ohos/src/main/ets/util/Log';
import { AbilityAware, AbilityPluginBinding, ByteBuffer } from '@ohos/flutter_ohos/index';
import { UIAbility } from '@kit.AbilityKit';
import { cameraPermission, checkPermissions, requestPermissions } from './CameraPermissions';
import { customScan, scanBarcode, scanCore, detectBarcode } from '@kit.ScanKit';
import EventChannel, { EventSink } from '@ohos/flutter_ohos/src/main/ets/plugin/common/EventChannel';
import { Barcode, BarcodeFormat, BarcodeType } from './Barcode';
import { BusinessError } from '@kit.BasicServicesKit';
import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';

const TAG: string = "mobile_scanner";

enum TorchState {
  off = 0,
  on = 1
}

export class MobileScannerPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  getUniqueClassName(): string {
    return "MobileScannerPlugin";
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    Log.i(TAG, "onAttachedToAbility");
    this.ability = binding.getAbility()
  }

  onDetachedFromAbility(): void {
    Log.i(TAG, "onDetachedFromAbility");
    this.ability = null;
  }

  private methodChannel: MethodChannel | null = null;
  private eventChannel: EventChannel | null = null;
  private eventSink: EventSink | null = null
  private applicationContext: Context | null = null;
  private ability: UIAbility | null = null;
  private textureId: number | null = null;
  private surfaceId: string | null = null;
  private binding: FlutterPluginBinding | null = null;
  private isStart = false;

  private cameraWidth: number = 0;
  private cameraHeight: number = 0;

  private photoSession: camera.PhotoSession | undefined = undefined;
  private imageReceiver: image.ImageReceiver | null = null

  publishEvent(event: ESObject) {
    this.eventSink?.success(event)
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.binding = binding;

    this.applicationContext = binding.getApplicationContext();
    this.methodChannel = new MethodChannel(binding.getBinaryMessenger(), "dev.steenbakker.mobile_scanner/scanner/method");
    this.methodChannel.setMethodCallHandler(this);

    this.eventChannel = new EventChannel(binding.getBinaryMessenger(), "dev.steenbakker.mobile_scanner/scanner/event");
    this.eventChannel.setStreamHandler({
      onListen: (args: Object, eventSink: EventSink) => {
        this.eventSink = eventSink;
      },
      onCancel: () => {
      }
    });

    // texture
    const textureRegistry = this.binding!.getTextureRegistry();
    const textureId = textureRegistry.getTextureId();
    const surfaceTextureEntry = textureRegistry.registerTexture(textureId);
    const surfaceId = surfaceTextureEntry.getSurfaceId().toString();
    this.textureId = textureId;
    this.surfaceId = surfaceId;
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.applicationContext = null;
    this.methodChannel?.setMethodCallHandler(null);
    this.methodChannel = null;

    this.eventChannel?.setStreamHandler(null);
    this.eventChannel = null;

    // unregisterTexture
    binding.getTextureRegistry().unregisterTexture(this.textureId);
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    try {
      if (call.method === "state") {
        checkPermissions(cameraPermission).then(hasCameraPermission => {
          if (hasCameraPermission) {
            result.success(1)
          } else {
            result.success(2)
          }
        });
        result.notImplemented()
      } else if (call.method === "request") {
        requestPermissions(this.ability!.context, (err, msg) => {
          if (err) {
            result.success(false)
          } else {
            result.success(true)
          }
        });
      } else if (call.method === "start") {
        this.start(call, result)
      } else if (call.method === "torch") {
        this.toggleTorch(call, result)
      } else if (call.method === "stop") {
        this.stop(result)
      } else if (call.method === "analyzeImage") {
        this.analyzeImage(call, result)
      } else if (call.method === "setScale") {
        this.setScale(call, result)
      } else if (call.method === "resetScale") {
        this.resetScale(result)
      } else if (call.method === "updateScanWindow") {
        this.updateScanWindow(call, result)
      } else {
        result.notImplemented()
      }
    } catch (err) {
      result.error("Name not found", err.message, null)
    }
  }

  async start(call: MethodCall, result: MethodResult) {
    const torch: boolean = call.argument("torch") ?? false
    const facing: number = call.argument("facing") ?? 0
    const formats: number[] = call.argument("formats")
    const returnImage: boolean = call.argument("returnImage") ?? false
    const speed: number = call.argument("speed") ?? 1
    const timeout: number = call.argument("timeout") ?? 250
    const cameraResolutionValues: number[] | undefined = call.argument("cameraResolution")
    const useNewCameraSelector: boolean = call.argument("useNewCameraSelector") ?? false
    let cameraResolution = [1080, 1920]
    if (!!cameraResolutionValues && cameraResolutionValues.length >= 2) {
      cameraResolution = [cameraResolutionValues[0], cameraResolutionValues[1]]
    }

    if (!this.isStart) {
      this.isStart = true;

      // 设置预览流高度，默认单位：vp
      const cameraHeight: number = px2vp(cameraResolution[1])
      // 设置预览流宽度，默认单位：vp
      const cameraWidth: number = px2vp(cameraResolution[0])

      this.cameraWidth = cameraWidth;
      this.cameraHeight = cameraHeight;

      this.imageReceiver = image.createImageReceiver(
        { width: this.cameraWidth, height: this.cameraHeight},
        image.ImageFormat.JPEG,
        1
      )

      this.cameraShootingCase()

      result.success({
        "textureId": this.textureId,
        "size": {
          "width": cameraWidth,
          "height": cameraHeight
        },
        "torchable": torch,
        "numberOfCameras": 1
      });

    } else {
      result.error(
        "MobileScanner",
        "Called start() while already started",
        null
      )
    }

  }

  setPhotoOutputCb(photoOutput: camera.PhotoOutput): void {
    this.imageReceiver?.on('imageArrival', () => {
      this.imageReceiver?.readNextImage((err: BusinessError, nextImage: image.Image) => {
        if (err || nextImage === undefined) {
          console.error('readNextImage failed');
          return
        }
        nextImage.getComponent(image.ComponentType.JPEG, (err: BusinessError, imageComponent: image.Component) => {
          if (err || nextImage === undefined) {
            console.error('getComponent failed')
          }
          if (imageComponent && imageComponent.byteBuffer as ArrayBuffer) {
            this.scanRelease(imageComponent.byteBuffer)
          } else {
            console.error('byteBuffer is null')
          }
          nextImage.release()
        })
      })
    })
  }

  async cameraShootingCase(): Promise<void> {
    // 创建CameraManager对象
    let cameraManager: camera.CameraManager = camera.getCameraManager(this.binding!.getApplicationContext());

    // 获取相机列表
    let cameraArray: Array<camera.CameraDevice> = cameraManager.getSupportedCameras();

    // 创建相机输入流
    let cameraInput: camera.CameraInput | undefined = undefined;
    cameraInput = cameraManager.createCameraInput(cameraArray[0]);

    // 打开相机
    await cameraInput.open();

    // 获取支持的模式类型
    let sceneModes: Array<camera.SceneMode> = cameraManager.getSupportedSceneModes(cameraArray[0]);
    let isSupportPhotoMode: boolean = sceneModes.indexOf(camera.SceneMode.NORMAL_PHOTO) >= 0;

    // 获取相机设备支持的输出流能力
    let cameraOutputCap: camera.CameraOutputCapability = cameraManager.getSupportedOutputCapability(cameraArray[0], camera.SceneMode.NORMAL_PHOTO);
    let previewProfilesArray: Array<camera.Profile> = cameraOutputCap.previewProfiles;
    let photoProfilesArray: Array<camera.Profile> = cameraOutputCap.photoProfiles;

    // 创建预览输出流,其中参数 surfaceId 参考上文 XComponent 组件，预览流为XComponent组件提供的surface
    let previewOutput: camera.PreviewOutput | undefined = undefined;
    previewOutput = cameraManager.createPreviewOutput(previewProfilesArray[0], this.surfaceId);

    // 创建拍照输出流
    let photoOutput: camera.PhotoOutput | undefined = undefined;
    photoOutput = cameraManager.createPhotoOutput(photoProfilesArray[0]);

    //调用上面的回调函数来保存图片
    this.setPhotoOutputCb(photoOutput);

    //创建会话
    this.photoSession = cameraManager.createSession(camera.SceneMode.NORMAL_PHOTO) as camera.PhotoSession;

    // 开始配置会话
    this.photoSession.beginConfig();

    // 向会话中添加相机输入流
    this.photoSession.addInput(cameraInput);

    // 向会话中添加预览输出流
    this.photoSession.addOutput(previewOutput);

    // 向会话中添加拍照输出流
    this.photoSession.addOutput(photoOutput);

    // 提交会话配置
    await this.photoSession.commitConfig();

    // 启动会话
    await this.photoSession.start().then(() => {
      console.info('Promise returned to indicate the session start success.');
    });

    setInterval(() => {
      let photoCaptureSetting: camera.PhotoCaptureSetting = {
        quality: camera.QualityLevel.QUALITY_LEVEL_HIGH, // 设置图片质量高
        rotation: camera.ImageRotation.ROTATION_0 // 设置图片旋转角度0
      }
      // 使用当前拍照设置进行拍照
      photoOutput!.capture(photoCaptureSetting, (err: BusinessError) => {
        if (err) {
          console.error(`Failed to capture the photo ${err.message}`);
          return;
        }
        console.info('Callback invoked to indicate the photo capture request success.');
      });
    }, 3000);
  }

  scanRelease(imageBuffer: ArrayBuffer) {
    console.log("Flutter------buffer", imageBuffer);
    let byteImg: detectBarcode.ByteImage = {
      byteBuffer: imageBuffer,
      width: this.cameraWidth,
      height: this.cameraHeight,
      format: detectBarcode.ImageFormat.NV21
    };
    let options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.ALL],
      enableMultiMode: true,
      enableAlbum: false
    };
    detectBarcode.decodeImage(byteImg, options).then((result: detectBarcode.DetectResult) => {
      console.log("Flutter------scanResults", result.scanResults);
      console.log("Flutter------zoomValue", result.zoomValue);
      console.info(TAG, 'Succeeded in getting DetectResult by promise by promise with options, result is ' + JSON.stringify(result));
      const _r: Barcode[] = result.scanResults.map(item => {
        console.log("Flutter-------originalValue", item.originalValue)
        console.log("Flutter-------scanType", item.scanType)
        console.log("Flutter-------scanCodeRect", item.scanCodeRect)
        console.log("Flutter-------cornerPoints", item.cornerPoints?.values())
        return {
          displayValue: item.originalValue,
          rawValue: item.originalValue,
          format: Barcode.convertScanType(item.scanType),
          type: BarcodeType.unknown,
          cornerPoints: item.cornerPoints
        } as Barcode;
      });
      this.publishEvent({
        "name": "barcode",
        "data": _r,
        "image": imageBuffer,
        "width": this.cameraWidth,
        "height": this.cameraHeight
      })
    }).catch((error: BusinessError) => {
      console.error(TAG, `Failed to get DetectResult by promise with options. Code: ${error.code}, message: ${error.message}`);
    })
  }

  startScan(cameraWidth: number, cameraHeight: number) {
    const viewControl: customScan.ViewControl = {
      width: cameraWidth,
      height: cameraHeight,
      surfaceId: this.surfaceId!,
    };

    customScan.start(viewControl).then((r: Array<scanBarcode.ScanResult>) => {
      const _r: Barcode[] = r.map(item => {
        return {
          displayValue: item.originalValue,
          rawValue: item.originalValue,
          format: Barcode.convertScanType(item.scanType),
          type: BarcodeType.unknown,
        } as Barcode;
      });
      this.callback(_r, null, cameraWidth, cameraHeight)
    });
  }

  async stop(result: MethodResult) {
    try {
      await customScan.stop();
      await customScan.release()
      this.photoSession?.release()
      this.imageReceiver?.release()
      this.photoSession = undefined
      this.imageReceiver = null
      this.isStart = false;
    } catch (e) {
    }
    result.success(null)
  }

  toggleTorch(call: MethodCall, result: MethodResult) {
    const light = customScan.getFlashLightStatus();
    if (light) {
      customScan.closeFlashLight()
    } else {
      customScan.openFlashLight()
    }
    this.publishEvent({
      name: 'torchState',
      data: customScan.getFlashLightStatus() ? TorchState.on : TorchState.off
    });
    result.success(null)
  }

  analyzeImage(call: MethodCall, result: MethodResult) {
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.ALL],
      enableMultiMode: true,
      enableAlbum: true
    }
    let inputImage: detectBarcode.InputImage = { uri: call.args }

    detectBarcode.decode(inputImage, options, (error: BusinessError, scanResult: Array<scanBarcode.ScanResult>) => {
      if (error && error.code) {
        Log.e(TAG, "analyzeImage:Callback Error:" + JSON.stringify(error));
        return
      }
      Log.d(TAG,  "analyzeImage:Callback scan result:" + JSON.stringify(scanResult));
      if (scanResult.length == 0) {
        result.success(false)
        return
      }

      const barcodes: Barcode[] = scanResult.map(item => {
        return {
          displayValue: item.originalValue,
          rawValue: item.originalValue,
          format: Barcode.convertScanType(item.scanType),
          type: BarcodeType.unknown,
        } as Barcode;
      });
      this.publishEvent({
        name: 'barcode',
        data: barcodes
      })

      result.success(true)
    })
  }

  setScale(call: MethodCall, result: MethodResult) {
    result.notImplemented()
  }

  resetScale(result: MethodResult) {
    result.notImplemented()
  }

  updateScanWindow(call: MethodCall, result: MethodResult) {
    result.notImplemented()
  }

  callback(barcodes: Barcode[], image: ByteBuffer | null, width: number, height: number) {
    // 需要先暂停后才能继续识别
    customScan.stop().then(() => {
      // 连续识别
      this.startScan(this.cameraWidth, this.cameraHeight)
      if (image) {
        this.publishEvent({
          "name": "barcode",
          "data": barcodes,
          "image": image,
          "width": width,
          "height": height
        })
      } else {
        this.publishEvent({
          "name": "barcode",
          "data": barcodes
        })
      }
    })
  }

  errorCallback(error: string) {
    this.publishEvent({
      "name": "error",
      "data": error
    })
  }
}