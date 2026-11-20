import Foundation

extension TryEntry {
    mutating func adoptOrganization(_ organizationID: String) throws {
        guard let index = learningOrganizations?.firstIndex(where: { $0.id == organizationID }),
              let draft = learningOrganizations?[index], draft.adoptedNoteID == nil,
              draft.sourceNotes.allSatisfy({ snapshot in learningNotes.contains { snapshot.matches($0) } }),
              draft.topicIDs.allSatisfy({ topic in learningTopics?.contains { $0.id == topic } == true }),
              draft.unitIDs.allSatisfy({ unit in learningUnits?.contains { $0.id == unit } == true }) else {
            throw TryDisk.Failure.changedAddition
        }
        if notes == nil { notes = learningNotes }
        let noteID = TryDisk.nextID(prefix: "N", ids: (notes ?? []).map(\.id))
        let now = Date().timeIntervalSince1970
        var note = TryLearningNote(id: noteID, title: draft.title, body: draft.body, createdAt: now, updatedAt: now)
        note.topicIDs = draft.topicIDs; note.unitIDs = draft.unitIDs
        note.origin = draft.sourceNotes.isEmpty ? "ai_supplement" : "ai_organized"
        note.sourceNotes = draft.sourceNotes
        notes?.append(note)
        learningOrganizations?[index].adoptedNoteID = noteID
        // The original pages, current freeform draft, selection and all checks remain intact.
    }
}
