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

            ForEach(locationService.routeSegments) { segment in
                if segment.coordinates.count > 1 {
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(.blue, lineWidth: 5)
                }
            }
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
        .onChange(of: acceptedLocationCount) { oldCount, newCount in
            guard oldCount == 0, newCount > 0 else {
                return
            }

            zoomToLatestLocation()
        }
    }

    private var acceptedLocationCount: Int {
        locationService.routeSegments.reduce(0) { count, segment in
            count + segment.coordinates.count
        }
    }

    /// Centers the map closely on the most recent accepted GPS point.
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
