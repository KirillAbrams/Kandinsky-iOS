import Foundation
enum SchemaMigrations {
  static let version: Int64 = 3
  static let legacy = [
    """
    CREATE TABLE IF NOT EXISTS chats(id INTEGER PRIMARY KEY,title TEXT NOT NULL,\
    avatarKind TEXT NOT NULL DEFAULT 'initial',lastMessageId INTEGER,\
    updatedSortKey INTEGER NOT NULL DEFAULT 0,unreadCount INTEGER NOT NULL DEFAULT 0,\
    pinned INTEGER NOT NULL DEFAULT 0)
    """,
    """
    CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY AUTOINCREMENT,\
    chatId INTEGER NOT NULL REFERENCES chats(id) ON DELETE CASCADE,sortKey INTEGER NOT NULL,\
    kind TEXT NOT NULL,text TEXT NOT NULL DEFAULT '',caption TEXT NOT NULL DEFAULT '',\
    replyToId INTEGER REFERENCES messages(id) ON DELETE \
    SET NULL,revision INTEGER NOT NULL DEFAULT 1,savedAt INTEGER NOT NULL)
    """,
    "CREATE INDEX IF NOT EXISTS messages_chat_sort ON messages(chatId,sortKey,id)",
    """
    CREATE TABLE IF NOT EXISTS attachments(id TEXT PRIMARY KEY,\
    messageId INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,\
    relativePath TEXT NOT NULL,mime TEXT NOT NULL,byteSize INTEGER NOT NULL,\
    width INTEGER NOT NULL DEFAULT 0,height INTEGER NOT NULL DEFAULT 0,durationMs INTEGER,\
    thumbnailKey TEXT NOT NULL DEFAULT '')
    """,
    "CREATE INDEX IF NOT EXISTS attachments_message ON attachments(messageId)",
    """
    CREATE TABLE IF NOT EXISTS drafts(chatId INTEGER PRIMARY KEY REFERENCES chats(id) ON \
    DELETE CASCADE,text TEXT NOT NULL,attachmentDraft TEXT)
    """,
    """
    CREATE TABLE IF NOT EXISTS reading_positions(chatId INTEGER PRIMARY KEY REFERENCES \
    chats(id) ON DELETE CASCADE,messageId INTEGER,offsetWithin TEXT NOT NULL,\
    followsBottom INTEGER NOT NULL,layoutVersion INTEGER NOT NULL)
    """,
    "CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)"
  ]
  static func apply(_ db: SQLiteConnection) throws {
    let old = try db.scalar("PRAGMA user_version")
    guard old <= version else { throw RepoError.corrupt }
    if old == version {
      try MediaSelectionStorage.install(db)
      try db.execute(
        """
        CREATE TABLE IF NOT EXISTS media_previews(attachmentID TEXT PRIMARY KEY REFERENCES \
        attachments(id) ON DELETE CASCADE,tinyPreview TEXT,waveform TEXT)
        """
      )
      try db.execute(
        "CREATE TABLE IF NOT EXISTS media_preview_catalog(key TEXT PRIMARY KEY,tinyPreview TEXT,waveform TEXT)"
      )
      try db.execute(
        """
        CREATE TABLE IF NOT EXISTS message_content(messageID INTEGER PRIMARY KEY REFERENCES \
        messages(id) ON DELETE CASCADE,consumed INTEGER NOT NULL DEFAULT 0 CHECK(consumed \
        IN (0,1)))
        """
      )
      return
    }
    try db.transaction {
      if old < 1 { for sql in legacy { try db.execute(sql) } }
      if old < 2 {
        try db.execute("ALTER TABLE messages ADD COLUMN direction TEXT NOT NULL DEFAULT 'incoming'")
        try db.execute("ALTER TABLE messages ADD COLUMN searchText TEXT NOT NULL DEFAULT ''")
        try db.execute("ALTER TABLE attachments ADD COLUMN orientation INTEGER NOT NULL DEFAULT 1")
        try db.execute("ALTER TABLE drafts ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
        try db.execute(
          "CREATE TABLE operations(token TEXT PRIMARY KEY,payloadHash TEXT NOT NULL,messageId INTEGER NOT NULL)"
        )
        var last: Int64 = 0
        while true {
          let rows = try db.rows(
            "SELECT id,text,caption FROM messages WHERE id>? ORDER BY id LIMIT 128",
            [.integer(last)])
          if rows.isEmpty { break }
          for row in rows {
            last = row["id"]!.int
            let folded = (row["text"]!.string + " " + row["caption"]!.string).lowercased()
            try db.execute(
              "UPDATE messages SET searchText=? WHERE id=?", [.text(folded), .integer(last)])
          }
        }
      }
      if old < 3 {
        try db.execute(
          "ALTER TABLE messages ADD COLUMN deliveryState TEXT NOT NULL DEFAULT 'local'")
      }
      try db.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('schema','3')")
      try db.execute(
        """
        CREATE TABLE IF NOT EXISTS media_previews(attachmentID TEXT PRIMARY KEY REFERENCES \
        attachments(id) ON DELETE CASCADE,tinyPreview TEXT,waveform TEXT)
        """
      )
      try db.execute(
        "CREATE TABLE IF NOT EXISTS media_preview_catalog(key TEXT PRIMARY KEY,tinyPreview TEXT,waveform TEXT)"
      )
      try db.execute(
        """
        CREATE TABLE IF NOT EXISTS message_content(messageID INTEGER PRIMARY KEY REFERENCES \
        messages(id) ON DELETE CASCADE,consumed INTEGER NOT NULL DEFAULT 0 CHECK(consumed \
        IN (0,1)))
        """
      )
      try MediaSelectionStorage.install(db)
      try db.execute("PRAGMA user_version=3")
    }
  }
}
