import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// PhotosPicker → image bytes. Prefer over `Data.self`, which only matches `public.data`
/// and often returns nil for library photos.
struct PickedImageData: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            PickedImageData(data: data)
        }
        DataRepresentation(importedContentType: .jpeg) { data in
            PickedImageData(data: data)
        }
        DataRepresentation(importedContentType: .heic) { data in
            PickedImageData(data: data)
        }
        DataRepresentation(importedContentType: .png) { data in
            PickedImageData(data: data)
        }
        DataRepresentation(importedContentType: .webP) { data in
            PickedImageData(data: data)
        }
    }
}
