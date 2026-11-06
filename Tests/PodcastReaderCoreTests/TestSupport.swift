import Foundation

func fixture(_ name: String) -> URL {
    Bundle.module.resourceURL!.appending(path: "Fixtures/\(name)")
}
