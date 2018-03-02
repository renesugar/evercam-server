defmodule SnapmailCamera do
  use EvercamMediaWeb, :model
  import Ecto.Query
  alias EvercamMedia.Repo

  @required_fields ~w(snapmail_id camera_id)

  schema "snapmail_cameras" do
    belongs_to :camera, Camera
    belongs_to :snapmail, Snapmail, foreign_key: :snapmail_id

    timestamps(type: Ecto.DateTime, default: Ecto.DateTime.utc)
  end

  def insert_cameras(snapmail_id, cameras) do
    cameras
    |> Enum.map(fn(camera) -> camera.id end)
    |> Enum.each(fn(id) ->
      params = %{camera_id: id, snapmail_id: snapmail_id}
      Repo.insert(changeset(%SnapmailCamera{}, params))
    end)
  end

  def delete_cameras(snapmail_id, cameras) do
    cameras
    |> Enum.map(fn(camera) -> camera.id end)
    |> Enum.each(fn(id) ->
      delete_by_snapmail_camera(snapmail_id, id)
    end)
  end

  def delete_by_snapmail(id) do
    SnapmailCamera
    |> where(snapmail_id: ^id)
    |> Repo.delete_all
  end

  def delete_by_snapmail_camera(id, camera_id) do
    SnapmailCamera
    |> where(snapmail_id: ^id)
    |> where(camera_id: ^camera_id)
    |> Repo.delete_all
  end

  def delete_by_camera_id(camera_id) do
    SnapmailCamera
    |> where(camera_id: ^camera_id)
    |> Repo.delete_all
  end

  def required_fields do
    @required_fields |> Enum.map(fn(field) -> String.to_atom(field) end)
  end

  def changeset(model, params \\ :invalid) do
    model
    |> cast(params, @required_fields)
    |> validate_required(required_fields())
  end
end
