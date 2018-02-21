defmodule CameraShareRequest do
  use EvercamMediaWeb, :model
  import Ecto.Query
  import CameraShare, only: [validate_rights: 1]
  alias EvercamMedia.Repo

  @required_fields ~w(camera_id user_id key email status rights)
  @optional_fields ~w(message created_at updated_at)
  @status %{pending: -1, cancelled: -2, used: 1}

  schema "camera_share_requests" do
    belongs_to :camera, Camera
    belongs_to :user, User

    field :key, :string
    field :email, :string
    field :rights, :string
    field :status, :integer
    field :message, :string
    timestamps(inserted_at: :created_at, type: Ecto.DateTime, default: Ecto.DateTime.utc)
  end

  def status, do: @status

  def by_camera_and_status(camera, nil) do
    CameraShareRequest
    |> where(camera_id: ^camera.id)
    |> preload(:camera)
    |> preload(:user)
    |> Repo.all
  end

  def by_camera_and_status(camera, status) do
    CameraShareRequest
    |> where(camera_id: ^camera.id)
    |> where(status: ^status)
    |> preload(:camera)
    |> preload(:user)
    |> Repo.all
  end

  def by_key_and_status(key, status \\ @status.pending) do
    CameraShareRequest
    |> where(status: ^status)
    |> where(key: ^key)
    |> preload(:camera)
    |> preload([camera: :owner])
    |> preload(:user)
    |> Repo.one
  end

  def by_key_and_email(nil, _key, _email), do: nil
  def by_key_and_email(camera, key, email) do
    CameraShareRequest
    |> where(status: ^@status.pending)
    |> where(camera_id: ^camera.id)
    |> where(key: ^key)
    |> where(email: ^email)
    |> preload(:camera)
    |> preload(:user)
    |> Repo.one
  end

  def by_email(email, status \\ @status.pending) do
    CameraShareRequest
    |> where(email: ^email)
    |> where(status: ^status)
    |> preload(:camera)
    |> preload([camera: :owner])
    |> preload(:user)
    |> Repo.all
  end

  def get_pending_request(_camera_id, email) when email in [nil, ""], do: :error
  def get_pending_request(camera_id, email) do
    CameraShareRequest
    |> where(camera_id: ^camera_id)
    |> where(status: ^@status.pending)
    |> where(email: ^String.downcase(email))
    |> preload(:camera)
    |> preload(:user)
    |> Repo.one
  end

  def get_all_pending_requests(day_before) do
    CameraShareRequest
    |> where(status: ^@status.pending)
    |> where([csr], csr.created_at >= ^day_before)
    |> preload(:camera)
    |> preload(:user)
    |> Repo.all
  end

  def get_status(status) do
    case status do
      "used" -> @status.used
      "cancelled" -> @status.cancelled
      "pending" -> @status.pending
    end
  end

  def create_share_request(camera, email, sharer, rights, message) do
    share_request_params = %{
      camera_id: camera.id,
      user_id: sharer.id,
      status: status().pending,
      email: email,
      rights: rights,
      message: message,
      key: UUID.uuid4(:hex)
    }
    changeset = insert_changeset(%CameraShareRequest{}, share_request_params)
    case Repo.insert(changeset) do
      {:ok, share_request} ->
        camera_share_request =
          share_request
          |> Repo.preload(:camera)
          |> Repo.preload(:user)
        {:ok, camera_share_request}
      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp share_request_exist(changeset, camera_field, email_field) do
    camera_id = get_field(changeset, camera_field)
    email = get_field(changeset, email_field)
    case get_pending_request(camera_id, email) do
      nil ->
        changeset
      :error -> changeset
      %CameraShareRequest{} ->
        add_error(changeset, email_field, "A share request already exists for the '#{email}' email address for this camera.")
    end
  end

  def delete_by_camera_id(camera_id) do
    CameraShareRequest
    |> where(camera_id: ^camera_id)
    |> Repo.delete_all
  end

  def delete_by_user_id(user_id) do
    CameraShareRequest
    |> where(user_id: ^user_id)
    |> Repo.delete_all
  end

  def insert_changeset(model, params \\ :invalid) do
    model
    |> changeset(params)
    |> share_request_exist(:camera_id, :email)
  end

  def update_changeset(model, params \\ :invalid) do
    changeset(model, params)
  end

  def required_fields do
    @required_fields |> Enum.map(fn(field) -> String.to_atom(field) end)
  end

  def changeset(model, params) do
    model
    |> cast(params, @required_fields ++ @optional_fields)
    |> validate_required(required_fields())
    |> validate_format(:email, ~r/^\S+@\S+$/, [message: "You've entered an invalid email address."])
    |> update_change(:email, &String.downcase/1)
    |> validate_rights
    |> update_change(:rights, &String.downcase/1)
    |> CameraShare.html_sanitize_message
  end
end
