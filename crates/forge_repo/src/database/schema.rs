// @generated automatically by Diesel CLI.

diesel::table! {
    conversations (conversation_id) {
        conversation_id -> Text,
        title -> Nullable<Text>,
        workspace_id -> BigInt,
        context -> Nullable<Text>,
        created_at -> Timestamp,
        updated_at -> Nullable<Timestamp>,
        metrics -> Nullable<Text>,
    }
}

diesel::table! {
    trajectory_events (id) {
        id -> Integer,
        conversation_id -> Text,
        agent_id -> Text,
        parent_agent_id -> Nullable<Text>,
        seq -> Integer,
        ts_ms -> BigInt,
        kind -> Text,
        payload -> Text,
    }
}

diesel::allow_tables_to_appear_in_same_query!(conversations, trajectory_events,);
