# frozen_string_literal: true

# Accounts are identified by EMAIL now (login = email + password). The short
# username becomes optional (kept as a nullable column for a possible future
# display handle; the in-game display name is the character's own name). Email
# already has a unique index; the app layer requires it.
Sequel.migration do
  change do
    alter_table(:accounts) do
      set_column_allow_null :username
    end
  end
end
