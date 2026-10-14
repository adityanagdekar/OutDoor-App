import CoreLocation
import MapKit
import SwiftUI

struct SessionMapView: View {
    let locationService: LocationService

    @State private var position: MapCameraPosition = .userLocation(
        fallback: SessionMapView.fallbackPosition
    )

    private static let fallbackPosition = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795),
            span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
        )
    )

    var body: some View {
        Map(position: $position) {
            UserAnnotation()
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onAppear {
            zoomToLatestLocation()
        }
        .onChange(of: locationService.mapLocation?.timestamp) {
            zoomToLatestLocation()
        }
    }

    /// Centers the map closely on the most recent reliable GPS position.
    private func zoomToLatestLocation() {
        guard let coordinate = (
            locationService.latestLocation ?? locationService.mapLocation
        )?.coordinate else {
            return
        }

        withAnimation {
            position = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: 800,
                    longitudinalMeters: 800
                )
            )
        }
    }
}
