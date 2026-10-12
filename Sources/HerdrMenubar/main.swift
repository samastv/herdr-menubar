import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let client = HerdrClient()
// Held at top level: the status item and its callbacks live only as long as the controller.
let controller = StatusController(client: client)
client.start()

app.run()
