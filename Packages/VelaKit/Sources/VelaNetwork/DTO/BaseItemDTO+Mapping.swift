import Foundation
import VelaCore

extension BaseItemDTO {
    func toMediaItem(serverID: String) -> MediaItem {
        var images: [MediaItem.ImageKind: String] = [:]
        for (key, tag) in imageTags ?? [:] {
            if let kind = MediaItem.ImageKind(rawValue: key) { images[kind] = tag }
        }
        var item = MediaItem(
            id: id,
            serverID: serverID,
            name: name ?? "",
            kind: Self.kind(from: type),
            overview: overview,
            productionYear: productionYear,
            seriesID: seriesID,
            seriesName: seriesName,
            indexNumber: indexNumber,
            parentIndexNumber: parentIndexNumber,
            runTimeTicks: runTimeTicks,
            playbackPositionTicks: userData?.playbackPositionTicks,
            isPlayed: userData?.played ?? false,
            isFavorite: userData?.isFavorite ?? false,
            communityRating: communityRating,
            officialRating: officialRating,
            genres: genres ?? [],
            imageTags: images,
            backdropImageTags: backdropImageTags ?? [],
            parentBackdropItemID: parentBackdropItemID,
            parentBackdropImageTags: parentBackdropImageTags ?? [],
            // 服务器返回的 provider key 大小写不统一（Tmdb / tmdb），统一小写便于匹配。
            providerIDs: Dictionary((providerIDs ?? [:]).map { ($0.key.lowercased(), $0.value) }) { first, _ in first },
            chapters: (chapters ?? []).map { chapter in
                MediaChapter(
                    name: chapter.name,
                    start: Ticks.seconds(chapter.startPositionTicks),
                    marker: chapter.markerType.flatMap(MediaChapter.Marker.init(rawValue:)) ?? .chapter,
                    imageTag: chapter.imageTag
                )
            },
            parentLogoItemID: parentLogoItemID,
            parentLogoImageTag: parentLogoImageTag,
            seasonID: seasonID,
            premiereDate: premiereDate,
            childCount: childCount,
            unplayedItemCount: userData?.unplayedItemCount,
            collectionType: collectionType,
            mediaSourceCount: (mediaSourceCount ?? 0) > 1 ? mediaSourceCount : nil
        )
        item.lastPlayedAt = userData?.lastPlayedDate
        item.path = path
        item.tags = tags ?? []
        item.video3DFormat = video3DFormat
        item.partCount = (partCount ?? 0) > 1 ? partCount : nil
        return item
    }

    static func kind(from type: String?) -> MediaItem.Kind {
        switch type {
        case "Movie": .movie
        case "Series": .series
        case "Season": .season
        case "Episode": .episode
        case "Video": .video
        case "MusicVideo": .musicVideo
        case "CollectionFolder", "UserView": .collectionFolder
        case "Folder": .folder
        case "BoxSet": .boxSet
        case "Playlist": .playlist
        case "Person": .person
        case "Audio": .audio
        default: .other
        }
    }
}
