// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

let delegate = SensorDaemon()
let listener = NSXPCListener(machServiceName: SensorServiceConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
