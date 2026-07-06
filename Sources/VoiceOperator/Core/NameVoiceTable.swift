import Foundation

/// 82 sticky operator call-signs paired with distinct Cartesia voices.
/// Regenerated 2026-07 with gender alignment: each pair's `gender` is the
/// voice's gender as reported by the Cartesia API (GET /voices/{id}), and the
/// call-sign is chosen to match it. The trailing comment on each row is the
/// voice's Cartesia catalog name. A session claims one (name, voice) pair; we
/// prefer never to reuse an active name or voice.
///
/// NameVoiceTableTests asserts name/voice gender alignment — keep it in sync
/// when adding names.
struct NamedVoice: Equatable, Sendable, Codable {
    let name: String
    let voiceID: String
    let gender: VoiceGender
}

/// Gender of a Cartesia voice, as reported by the API.
enum VoiceGender: String, Sendable, Codable {
    case masculine
    case feminine
}

enum NameVoiceTable {
    static let all: [NamedVoice] = [
        NamedVoice(name: "Oliver", voiceID: "00967b2f-88a6-4a31-8153-110a92134b9f", gender: .masculine),  // Asher - Podcaster
        NamedVoice(name: "Chloe", voiceID: "00a77add-48d5-4ef6-8157-71e5437b282d", gender: .feminine),  // Callie - Encourager
        NamedVoice(name: "Claire", voiceID: "02a924f6-bb49-4177-8fbb-52238c5056d6", gender: .feminine),  // Maeve - Steady Host
        NamedVoice(name: "Diana", voiceID: "03496517-369a-4db1-8236-3d3ae459ddf7", gender: .feminine),  // Calypso - ASMR Lady
        NamedVoice(name: "Emma", voiceID: "043cfc81-d69f-4bee-ae1e-7862cb358650", gender: .feminine),  // Amelia - Instructor
        NamedVoice(name: "Sadie", voiceID: "072d954b-8379-4b6b-816a-bb0cd38725f8", gender: .feminine),  // Anele - Bright Presenter
        NamedVoice(name: "Molly", voiceID: "0c8ed86e-6c64-40f0-b252-b773911de6bb", gender: .feminine),  // Doris - Friend
        NamedVoice(name: "Fiona", voiceID: "0ee8beaa-db49-4024-940d-c7ea09b590b3", gender: .feminine),  // Morgan - Executive Expert
        NamedVoice(name: "Grace", voiceID: "10bd4af4-825b-49b8-b8bd-0ca11865536e", gender: .feminine),  // Rachel - Polished Presence
        NamedVoice(name: "Hazel", voiceID: "11af83e2-23eb-452f-956e-7fee218ccb5c", gender: .feminine),  // Ruth - Manager
        NamedVoice(name: "Heidi", voiceID: "1242fb95-7ddd-44ac-8a05-9e8a22a6137d", gender: .feminine),  // Cindy - Receptionist
        NamedVoice(name: "Logan", voiceID: "1259b7e3-cb8a-43df-9446-30971a46b8b0", gender: .masculine),  // Devansh - Warm Support Agent
        NamedVoice(name: "Ivy", voiceID: "134838f5-ce7e-4876-ac32-6367b99daf83", gender: .feminine),  // Madison - Best Friend
        NamedVoice(name: "Caleb", voiceID: "13524ffb-a918-499a-ae97-c98c7c4408c4", gender: .masculine),  // Barry - Helper
        NamedVoice(name: "Isaac", voiceID: "146485fd-8736-41c7-88a8-7cdd0da34d84", gender: .masculine),  // Tim - Pal
        NamedVoice(name: "Blake", voiceID: "17044048-bfab-44b2-9532-9c1b65e9c217", gender: .masculine),  // Alec - Spirited Salesman
        NamedVoice(name: "Jane", voiceID: "1a0c6bb2-bc1b-476e-8d45-56a66300362b", gender: .feminine),  // Esther - Gracious Helper
        NamedVoice(name: "Iris", voiceID: "1e9b9b3d-d2ce-4cac-9d05-bc36a63fa28e", gender: .feminine),  // Saira - Organized Coordinator
        NamedVoice(name: "Evan", voiceID: "1ec736fa-db96-4eea-9299-235ce2cb7a0e", gender: .masculine),  // Conor - Decisive Agent
        NamedVoice(name: "Grant", voiceID: "1fc31370-81b1-4588-9c1a-f93793c6e01d", gender: .masculine),  // Carlo - Roman Guide
        NamedVoice(name: "Lily", voiceID: "21b81c14-f85b-436d-aff5-43f2e788ecf8", gender: .feminine),  // Riley - Chill Friend
        NamedVoice(name: "Kyle", voiceID: "22df7143-7987-4e15-a720-d65c69a443b3", gender: .masculine),  // Oscar - Clear Specialist
        NamedVoice(name: "Luke", voiceID: "23e9e50a-4ea2-447b-b589-df90dbb848a2", gender: .masculine),  // Dallas - Fireside Friend
        NamedVoice(name: "Lucy", voiceID: "248be419-c632-4f23-adf1-5324ed7dbf1d", gender: .feminine),  // Elizabeth - Manager
        NamedVoice(name: "Maya", voiceID: "25bf938a-025c-4dd0-906f-8cf8be2e26e9", gender: .feminine),  // Loretta - Still Comfort
        NamedVoice(name: "Mia", voiceID: "25d7abcb-4d6d-4aca-adce-8a1c85620c8b", gender: .feminine),  // Jessica - Clear Communicator
        NamedVoice(name: "Nina", voiceID: "263b9cc0-0d99-44e7-ae92-3d4ad5d2ad18", gender: .feminine),  // Zanele - Vibrant Advocate
        NamedVoice(name: "Daphne", voiceID: "2a17e905-8f14-4db7-9b9d-9223a8e3f278", gender: .feminine),  // Jane - Digital Guide
        NamedVoice(name: "Wade", voiceID: "2a4d065a-ac91-4203-a015-eb3fc3ee3365", gender: .masculine),  // Wes - Customer Companion
        NamedVoice(name: "Nora", voiceID: "2f251ac3-89a9-4a77-a452-704b474ccd01", gender: .feminine),  // Lucy - Capable Coordinator
        NamedVoice(name: "Olivia", voiceID: "32b3f3c5-7171-46aa-abe7-b598964aa793", gender: .feminine),  // Daisy - Reading Girl
        NamedVoice(name: "Harvey", voiceID: "34575e71-908f-4ab6-ab54-b08c95d6597d", gender: .masculine),  // Joey - Neighborhood Guy
        NamedVoice(name: "Leon", voiceID: "34d923aa-c3b5-4f21-aac7-2c1f12730d4b", gender: .masculine),  // Griffin - Excited Narrator
        NamedVoice(name: "Penny", voiceID: "358e650d-ac0b-4a74-b14f-aca3daa40d79", gender: .feminine),  // Kendra - Smooth Communicator
        NamedVoice(name: "Oscar", voiceID: "39b376fc-488e-4d0c-8b37-e00b72059fdd", gender: .masculine),  // Sheldon - Help Desk Man
        NamedVoice(name: "Ruby", voiceID: "3b554273-4299-48b9-9aaf-eefd438e3941", gender: .feminine),  // Simi - Support Specialist
        NamedVoice(name: "Victor", voiceID: "3c0f09d6-e0d7-499c-a594-70c5b7b93048", gender: .masculine),  // Benedict - Measured Mediator
        NamedVoice(name: "George", voiceID: "3d79b1fd-daaa-439c-bff3-903dc18e7684", gender: .masculine),  // Luke - Happy Broadway Voice
        NamedVoice(name: "Jonah", voiceID: "3e39e9a5-585c-4f5f-bac6-5e4905c51095", gender: .masculine),  // Cole - Clear Communicator
        NamedVoice(name: "Roland", voiceID: "40104aff-a015-4da1-9912-af950fbec99e", gender: .masculine),  // Travis - How To Guide
        NamedVoice(name: "Stella", voiceID: "4111bc29-d7ff-4a15-90db-819f7b4f7706", gender: .feminine),  // Clementine - Hospitable Host
        NamedVoice(name: "Bruno", voiceID: "41534e16-2966-4c6b-9670-111411def906", gender: .masculine),  // Clarence - Newsman
        NamedVoice(name: "Dean", voiceID: "41f3c367-e0a8-4a85-89e0-c27bae9c9b6d", gender: .masculine),  // Liam - Guy Next Door
        NamedVoice(name: "Ethan", voiceID: "4703c250-66e4-4682-a223-0a60acafcfc0", gender: .masculine),  // Levi - Steady Spokesman
        NamedVoice(name: "Henry", voiceID: "49743b08-0f5d-4741-839c-b12933853780", gender: .masculine),  // Cooper - Friendly Mate
        NamedVoice(name: "Jack", voiceID: "4b31d090-8d2d-4bcd-8a32-1c135301e26e", gender: .masculine),  // Johan - Deep Consultant
        NamedVoice(name: "Jake", voiceID: "4bc3cb8c-adb9-4bb8-b5d5-cbbef950b991", gender: .masculine),  // George - Composed Consultant
        NamedVoice(name: "Leo", voiceID: "4df027cb-2920-4a1f-8c34-f21529d5c3fe", gender: .masculine),  // Carson - Friendly Support
        NamedVoice(name: "Lucas", voiceID: "4f7f1324-1853-48a6-b294-4e78e8036a83", gender: .masculine),  // Casper - Gentle Narrator
        NamedVoice(name: "Marcus", voiceID: "4fb26a05-57de-4d21-855a-f51adae44f38", gender: .masculine),  // Barry 2.0 - Helper
        NamedVoice(name: "Mark", voiceID: "533b2990-5b82-45a4-b9f2-367776972ca6", gender: .masculine),  // Reed - Polished Professional
        NamedVoice(name: "Kate", voiceID: "55deba52-bc73-4481-ab69-9c8831c8a7c3", gender: .feminine),  // Camille - Friendly Expert
        NamedVoice(name: "Mason", voiceID: "5619d38c-cf51-4d8e-9575-48f61a280413", gender: .masculine),  // Mark - Promotion Lead
        NamedVoice(name: "Max", voiceID: "565510e8-6b45-45de-8758-13588fbaec73", gender: .masculine),  // Ray - Conversationalist
        NamedVoice(name: "Rose", voiceID: "56b87df1-594d-4135-992c-1112bb504c59", gender: .feminine),  // Lexi - Fun Friend
        NamedVoice(name: "Tessa", voiceID: "57b6bf63-c7a1-4ffc-8e10-23bf45152dd6", gender: .feminine),  // Rebecca - Counselor
        NamedVoice(name: "Beth", voiceID: "57c63422-d911-4666-815b-0c332e4d7d6a", gender: .feminine),  // Lori - Cheerleader
        NamedVoice(name: "Dana", voiceID: "58fbaf73-d7de-4e82-a6b3-118180e7057c", gender: .feminine),  // Janet - Sunny Speaker
        NamedVoice(name: "Gemma", voiceID: "5a93ae96-9e3e-4b9d-8575-5f62b7de6d0f", gender: .feminine),  // Imogen - Polished Guide
        NamedVoice(name: "Julia", voiceID: "5abd2130-146a-41b1-bcdb-974ea8e19f56", gender: .feminine),  // Jo - Go to Gal
        NamedVoice(name: "Laura", voiceID: "5c42302c-194b-4d0c-ba1a-8cb485c84ab9", gender: .feminine),  // Mary - Nurse
        NamedVoice(name: "Miles", voiceID: "5e7d492a-5502-482e-b315-ebf587427806", gender: .masculine),  // Alfie - Composed Advisor
        NamedVoice(name: "Nathan", voiceID: "5ee9feff-1265-424a-9d7f-8e4d431a12c7", gender: .masculine),  // Ronald - Thinker
        NamedVoice(name: "Rachel", voiceID: "5f621418-ab01-4bf4-9a9d-73d66032234e", gender: .feminine),  // Willow - Approachable Ally
        NamedVoice(name: "Noah", voiceID: "5fc5c797-12c5-4f2b-ac9b-d4e53c08098f", gender: .masculine),  // Wyatt - Dependable Dispatcher
        NamedVoice(name: "Wendy", voiceID: "607167f6-9bf2-473c-accc-ac7b3b66b30b", gender: .feminine),  // Brenda - Host
        NamedVoice(name: "Bella", voiceID: "62ae83ad-4f6a-430b-af41-a9bede9286ca", gender: .feminine),  // Gemma - Decisive Agent
        NamedVoice(name: "Ross", voiceID: "630ed21c-2c5c-41cf-9d82-10a7fd668370", gender: .masculine),  // Corey - Supportive Buddy
        NamedVoice(name: "Scott", voiceID: "638efaaa-4d0c-442e-b701-3fae16aad012", gender: .masculine),  // Sameer - Problem Solver
        NamedVoice(name: "Simon", voiceID: "65209f8e-6140-4a20-b819-3cc2e21da19b", gender: .masculine),  // Nolan - Expressive Agent
        NamedVoice(name: "Vincent", voiceID: "68fb6747-b6ea-4c44-a18e-4e29921424d3", gender: .masculine),  // Derek - Deep Advisor
        NamedVoice(name: "Naomi", voiceID: "692846ad-1a6b-49b8-bfc5-86421fd41a19", gender: .feminine),  // Thandi - Direct Dispatcher
        NamedVoice(name: "Rita", voiceID: "694f9389-aac1-45b6-b726-9d9369183238", gender: .feminine),  // Sarah - Mindful Woman
        NamedVoice(name: "Vivian", voiceID: "6a73e45f-3fa6-427c-97da-0fc6a7a1bc0d", gender: .feminine),  // Stephanie - Steady Professional
        NamedVoice(name: "Wesley", voiceID: "701a96e1-7fdd-4a6c-a81e-a4a450403599", gender: .masculine),  // Rowan - Team Leader
        NamedVoice(name: "Ruth", voiceID: "71a7ad14-091c-4e8e-a314-022ece01c121", gender: .feminine),  // Charlotte - Heiress
        NamedVoice(name: "Wyatt", voiceID: "726d5ae5-055f-4c3d-8355-d9677de68937", gender: .masculine),  // Troy - Fix It Man
        NamedVoice(name: "Nolan", voiceID: "729651dc-c6c3-4ee5-97fa-350da1f88600", gender: .masculine),  // Jake - Sidekick
        NamedVoice(name: "Piper", voiceID: "761afc95-bef5-44dd-aa07-d3c678912e43", gender: .feminine),  // Samantha - Happy Support Leader
        NamedVoice(name: "Zoe", voiceID: "78ab82d5-25be-4f7d-82b3-7ad64e5b85b2", gender: .feminine),  // Savannah - Magnolia Belle
        NamedVoice(name: "Felix", voiceID: "79bfcec0-720c-41f2-a33a-f12383e9627f", gender: .masculine),  // Wang - Guide
        NamedVoice(name: "Jasper", voiceID: "79f8b5fb-2cc8-479a-80df-29f7a7cf1a3e", gender: .masculine),  // Theo - Modern Narrator
    ]
}
