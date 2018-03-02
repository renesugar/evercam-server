defmodule SnapshotExtractor do
  use EvercamMediaWeb, :model
  import Ecto.Changeset
  import Ecto.Query
  alias EvercamMedia.Repo

  @required_fields ~w(camera_id to_date from_date status interval schedule)
  @optional_fields ~w(notes requestor updated_at created_at)

  schema "snapshot_extractors" do
    belongs_to :camera, Camera, foreign_key: :camera_id

    field :from_date, Ecto.DateTime, default: Ecto.DateTime.utc
    field :to_date, Ecto.DateTime, default: Ecto.DateTime.utc
    field :interval, :integer
    field :schedule, EvercamMedia.Types.JSON
    field :status, :integer
    field :notes, :string
    field :requestor, :string
    timestamps(inserted_at: :created_at, type: Ecto.DateTime, default: Ecto.DateTime.utc)
  end

  def by_id(id) do
    SnapshotExtractor
    |> where(id: ^id)
    |> preload(:camera)
    |> Repo.one
  end

  def update_snapshot_extactor(snapshot_extactor, params) do
    snapshot_extactor_changeset = changeset(snapshot_extactor, params)
    case Repo.update(snapshot_extactor_changeset) do
      {:ok, extractor} ->
        full_extractor = Repo.preload(extractor, :camera)
        {:ok, full_extractor}
      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def delete_by_camera_id(camera_id) do
    SnapshotExtractor
    |> where(camera_id: ^camera_id)
    |> Repo.delete_all
  end

  def required_fields do
    @required_fields |> Enum.map(fn(field) -> String.to_atom(field) end)
  end

  def changeset(snapshot_extractor, params \\ :invalid) do
    snapshot_extractor
    |> cast(params, @required_fields ++ @optional_fields)
    |> validate_required(required_fields())
  end
end
