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
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Point } from '@ohos.UiTest';

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

  private scanWidth: number = 384 // xComponent宽度，默认设置384，单位vp
  private scanHeight: number = 682 // xComponent高度，默认设置682，单位vp
  private scanCodeRect: Array<scanBarcode.ScanCodeRect> = [] // 扫码结果码图位置
  private scanBottom: number = 220
  private displayHeight: number = 0 // 屏幕高度，单位vp
  private displayWidth: number = 0 // 屏幕宽度，单位vp

  private scanWindow: Array<number> | null = null;  // scanWindow，扫描区域

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

      this.setDisplay()

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

  // 返回自定义扫描结果的回调
  private scanCallback: AsyncCallback<scanBarcode.ScanResult[]> =
    async (error: BusinessError, result: scanBarcode.ScanResult[]) => {
      if (error && error.code) {
        hilog.error(0x0001, TAG,
          `Failed to get ScanResult by callback. Code: ${error.code}, message: ${error.message}`);
        return;
      }
      // 解析码值结果跳转应用服务页
      hilog.info(0x0001, TAG, `Succeeded in getting ScanResult by callback, result: ${JSON.stringify(result)}`);
      let i = 0
      let first: boolean = true
      const _r: Barcode[] = result.map(item => {
        if (first) {
          first = false
        } else {
          i++
        }
        return {
          displayValue: item.originalValue,
          rawValue: item.originalValue,
          format: Barcode.convertScanType(item.scanType),
          type: BarcodeType.unknown,
          corners: [
            {x: this.scanCodeRect[i]?.left, y: this.scanCodeRect[i]?.top} as Point,
            {x: this.scanCodeRect[i]?.right, y: this.scanCodeRect[i]?.top} as Point,
            {x: this.scanCodeRect[i]?.right, y: this.scanCodeRect[i]?.bottom} as Point,
            {x: this.scanCodeRect[i]?.left, y: this.scanCodeRect[i]?.bottom} as Point,
          ].map(i => ({
            x: i.x / this.scanWidth * this.cameraWidth,
            y: i.y / this.scanHeight * this.cameraHeight
          }) as Point)
        } as Barcode;
      }).filter(barcode => {
        if (this.scanWindow) {
          return this.isBarcodeInScanWindow(barcode);
        }
        else {
          return true;
        }
      });
      this.callback(_r, null, this.cameraWidth, this.cameraHeight)
    }

  // 返回相机帧的回调
  private frameCallback: AsyncCallback<customScan.ScanFrame> =
    async (error: BusinessError, frameResult: customScan.ScanFrame) => {
      if (error) {
        hilog.error(0x0001, TAG, `Failed to get ScanFrame by callback. Code: ${error.code}, message: ${error.message}`);
        return;
      }
      if (frameResult && frameResult.scanCodeRects && frameResult.scanCodeRects.length > 0) {
        if (frameResult.scanCodeRects[0]) {
          this.scanCodeRect = [];
          // 码图位置信息转换
          this.changeToXComponent(frameResult);
        } else {
          hilog.error(0x0001, TAG, `Failed to get scanCodeRects by callback`);
        }
      }
    }

  // frameCallback横向码图位置信息转换为预览流xComponent对应码图位置信息
  changeToXComponent(frameResult: customScan.ScanFrame) {
    if (frameResult && frameResult.scanCodeRects) {
      let frameHeight = frameResult.height;
      let ratio = this.scanWidth / frameHeight;
      frameResult.scanCodeRects.forEach((item) => {
        this.scanCodeRect.push({
          left: this.toFixedNumber((frameHeight - item.bottom) * ratio),
          top: this.toFixedNumber(item.left * ratio),
          right: this.toFixedNumber((frameHeight - item.top) * ratio),
          bottom: this.toFixedNumber(item.right * ratio)
        });
      });
    }
  }

  startScan(cameraWidth: number, cameraHeight: number) {
    const viewControl: customScan.ViewControl = {
      width: cameraWidth,
      height: cameraHeight,
      surfaceId: this.surfaceId!,
    };

    customScan.start(viewControl, this.scanCallback, this.frameCallback)
  }

  // 竖屏时获取屏幕尺寸，设置预览流全屏示例
  setDisplay() {
    // 以手机为例计算宽高
    let displayClass = display.getDefaultDisplaySync();
    this.displayHeight = px2vp(displayClass.height);
    this.displayWidth = px2vp(displayClass.width);
    if (displayClass !== null) {
      this.scanWidth = px2vp(displayClass.width);
      this.scanHeight = Math.round(this.scanWidth * this.cameraWidth / this.cameraHeight);
      this.scanBottom = Math.max(220, px2vp(displayClass.height) - this.scanHeight);
    }
  }

  toFixedNumber(no: number): number {
    return Number((no).toFixed(1));
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
        let cornerPoints = item.cornerPoints;
        let corners: Array<Point> = []
        if (cornerPoints != undefined && cornerPoints != null) {
          corners = [
            {x: this.cameraWidth - cornerPoints[0].y, y: cornerPoints[0].x},
            {x: this.cameraWidth - cornerPoints[1].y, y: cornerPoints[1].x},
            {x: this.cameraWidth - cornerPoints[2].y, y: cornerPoints[2].x},
            {x: this.cameraWidth - cornerPoints[3].y, y: cornerPoints[3].x},
          ]
        }
        return {
          displayValue: item.originalValue,
          rawValue: item.originalValue,
          format: Barcode.convertScanType(item.scanType),
          type: BarcodeType.unknown,
          corners: corners
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
    this.scanWindow = call.argument("rect")
    result.success(true)
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

  private isBarcodeInScanWindow(barcode: Barcode): boolean {
    const corners = barcode.corners;
    const top = this.scanWindow![1] * this.cameraHeight;
    const bottom = this.scanWindow![3] * this.cameraHeight;
    const left = this.scanWindow![0] * this.cameraWidth;
    const right = this.scanWindow![2] * this.cameraWidth;
    return corners.reduce((r, item) => r && item.x > left && item.x < right && item.y > top && item.y < bottom, true)
  }

  errorCallback(error: string) {
    this.publishEvent({
      "name": "error",
      "data": error
    })
  }
}