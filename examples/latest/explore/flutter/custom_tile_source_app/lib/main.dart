/*
 * Copyright (C) 2025 HERE Europe B.V.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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
 *
 * SPDX-License-Identifier: Apache-2.0
 * License-Filename: LICENSE
 */

import 'package:flutter/material.dart';
import 'package:here_sdk/core.dart';
import 'package:here_sdk/core.engine.dart';
import 'package:here_sdk/core.errors.dart';
import 'package:here_sdk/mapview.dart';
import 'CustomPointTileSourceExample.dart';
import 'CustomRasterTileSourceExample.dart';

void main() {
  // Usually, you need to initialize the HERE SDK only once during the lifetime of an application.
  _initializeHERESDK();

  runApp(
    MaterialApp(
      home: MyApp(),
    ),
  );
}

void _initializeHERESDK() async {
  // Needs to be called before accessing SDKOptions to load necessary libraries.
  SdkContext.init(IsolateOrigin.main);

  // Set your credentials for the HERE SDK.
  String accessKeyId = "YOUR_ACCESS_KEY_ID";
  String accessKeySecret = "YOUR_ACCESS_KEY_SECRET";
  AuthenticationMode authenticationMode =
      AuthenticationMode.withKeySecret(accessKeyId, accessKeySecret);
  SDKOptions sdkOptions = SDKOptions.withAuthenticationMode(authenticationMode);

  try {
    await SDKNativeEngine.makeSharedInstance(sdkOptions);
  } on InstantiationException {
    throw Exception("Failed to initialize the HERE SDK.");
  }
}

class MyApp extends StatefulWidget {
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  CustomPointTileSourceExample? _customPointTileSourceExample;
  CustomRasterTileSourceExample? _customRasterTileSourceExample;
  late final AppLifecycleListener _listener;
  String _selectedTileSource = "point";

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: Text('Custom Point Tile Source'),
        ),
        body: Stack(
          children: [
            HereMap(onMapCreated: _onMapCreated),
            Align(
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min, // Prevent extra spacing
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Radio<String>(
                            value: "point",
                            groupValue: _selectedTileSource,
                            onChanged: (value) {
                              setState(() {
                                _selectedTileSource = "point";
                              });
                            },
                          ),
                          Text("Point tile source",
                              style: TextStyle(color: Colors.black)),
                        ],
                      ),
                      Row(
                        children: [
                          Radio<String>(
                            value: "raster",
                            groupValue: _selectedTileSource,
                            onChanged: (value) {
                              setState(() {
                                _selectedTileSource = "raster";
                              });
                            },
                          ),
                          Text("Raster tile source",
                              style: TextStyle(color: Colors.black)),
                        ],
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      button('Enable', _enableButtonClicked),
                      button('Disable', _disableButtonClicked),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onMapCreated(HereMapController hereMapController) {
    hereMapController.mapScene.loadSceneForMapScheme(MapScheme.normalDay,
        (MapError? error) {
      if (error == null) {
        _customPointTileSourceExample =
            CustomPointTileSourceExample(hereMapController);
        _customRasterTileSourceExample =
            CustomRasterTileSourceExample(hereMapController);
        _customRasterTileSourceExample?.setup();
      } else {
        print("Map scene not loaded. MapError: " + error.toString());
      }
    });
  }

  void _enableButtonClicked() {
    if (_selectedTileSource == "point") {
      _customPointTileSourceExample?.enableButtonClicked();
    } else {
      _customRasterTileSourceExample?.enableButtonClicked();
    }
  }

  void _disableButtonClicked() {
    if (_selectedTileSource == "point") {
      _customPointTileSourceExample?.disableButtonClicked();
    } else {
      _customRasterTileSourceExample?.disableButtonClicked();
    }
  }

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(
      onDetach: () =>
          // Sometimes Flutter may not reliably call dispose(),
          // therefore it is recommended to dispose the HERE SDK
          // also when the AppLifecycleListener is detached.
          // See more details: https://github.com/flutter/flutter/issues/40940
          {print('AppLifecycleListener detached.'), _disposeHERESDK()},
    );
  }

  @override
  void dispose() {
    _disposeHERESDK();
    super.dispose();
  }

  void _disposeHERESDK() async {
    // Free HERE SDK resources before the application shuts down.
    _customPointTileSourceExample?.onDestroy();
    await SDKNativeEngine.sharedInstance?.dispose();
    SdkContext.release();
    _listener.dispose();
  }

  // A helper method to add a button on top of the HERE map.
  Align button(String buttonLabel, Function callbackFunction) {
    return Align(
      alignment: Alignment.topCenter,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: Colors.lightBlueAccent,
        ),
        onPressed: () => callbackFunction(),
        child: Text(buttonLabel, style: TextStyle(fontSize: 20)),
      ),
    );
  }

  // A helper method to show a dialog.
  Future<void> _showDialog(String title, String message) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(message),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: Text("OK"),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }
}
