# frozen_string_literal: true

# Milestone 4 Layer B — server-owned spawn. Persist the last SERVER-VALIDATED player
# position (map,x,y) alongside the opaque save. At login the server seeds the
# position audit's last_pos with it, so the very first presence frame is CHECKED: a
# normal spawn (blob position == last validated position) matches; a save-edited
# spawn is caught by the existing PositionAudit + snap-back — no new client message.
# Nullable: accounts without a validated position yet fall back to the unchecked
# first frame (backwards-compatible).
Sequel.migration do
  change do
    alter_table(:characters) do
      add_column :last_map, Integer
      add_column :last_x,   Integer
      add_column :last_y,   Integer
    end
  end
end
