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
    let cameraResolution = [360, 360]
    if (!!cameraResolutionValues && cameraResolutionValues.length >= 2) {
      cameraResolution = [cameraResolutionValues[0], cameraResolutionValues[1]]
    }

    if (!this.isStart) {
      this.isStart = true;

      let scanTypes = [scanCore.ScanType.ALL]
      if (formats) {
        scanTypes = []
        formats.forEach((format:number) => {
          let type = Barcode.convertToScanType(format)
          if (type != scanCore.ScanType.FORMAT_UNKNOWN) {
            scanTypes.push(type)
          }
        })
      }

      const options: scanBarcode.ScanOptions = {
        scanTypes: scanTypes,
        enableMultiMode: true,
        enableAlbum: true
      }
      customScan.init(options);

      // 设置预览流高度，默认单位：vp
      const cameraHeight: number = px2vp(cameraResolution[1])
      // 设置预览流宽度，默认单位：vp
      const cameraWidth: number = px2vp(cameraResolution[0])

      this.cameraWidth = cameraWidth;
      this.cameraHeight = cameraHeight;

      this.startScan(cameraWidth, cameraHeight)

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

