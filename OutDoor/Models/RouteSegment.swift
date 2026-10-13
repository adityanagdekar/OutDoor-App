import CoreLocation
import Foundation

struct RouteSegment: Identifiable {
    let id = UUID()
    var coordinates: [CLLocationCoordinate2D]
}
