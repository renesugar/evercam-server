defmodule EvercamMediaWeb.CameraShareRequestController do
  use EvercamMediaWeb, :controller
  alias EvercamMediaWeb.CameraShareRequestView
  alias EvercamMedia.Intercom

  def show(conn, %{"id" => exid} = params) do
    caller = conn.assigns[:current_user]
    camera = Camera.get_full(exid)
    status = parse_status(params["status"])

    with :ok <- camera_exists(conn, exid, camera),
         :ok <- caller_has_rights(conn, caller, camera)
    do
     share_requests = CameraShareRequest.by_camera_and_status(camera, status)

      conn
      |> render(CameraShareRequestView, "index.json", %{camera_share_requests: share_requests})
    end
  end

  def update(conn, %{"id" => exid, "email" => email, "rights" => rights}) do
    caller = conn.assigns[:current_user]
    camera = Camera.get_full(exid)

    with :ok <- camera_exists(conn, exid, camera),
         :ok <- caller_has_rights(conn, caller, camera),
         {:ok, share_request} <- share_request_exists(conn, email, camera)
    do
      share_request
      |> CameraShareRequest.update_changeset(%{rights: rights})
      |> Repo.update
      |> case do
        {:ok, camera_share_request} ->
          conn
          |> render(CameraShareRequestView, "show.json", %{camera_share_requests: camera_share_request})
        {:error, changeset} ->
          conn
          |> render_error(400, Util.parse_changeset(changeset))
      end
    end
  end

  def cancel(conn, %{"id" => exid, "email" => email} = params) do
    caller = conn.assigns[:current_user]
    camera = Camera.get_full(exid)
    key = params["key"]

    with :ok <- camera_exists(conn, exid, camera),
         :ok <- caller_has_rights(conn, caller, camera),
         {:ok, share_request} <- has_share_request(conn, email, camera, key)
    do
      params = %{rights: share_request.rights, status: CameraShareRequest.status.cancelled}

      share_request
      |> CameraShareRequest.update_changeset(params)
      |> Repo.update!
      |> revoked_notification(key)
      Intercom.delete_or_update_user(Application.get_env(:evercam_media, :create_intercom_user), email, get_user_agent(conn), user_request_ip(conn), key)
      json(conn, %{})
    end
  end

  defp revoked_notification(_share_request, key) when key in [nil, ""], do: :noop
  defp revoked_notification(share_request, _key) do
    try do
      Task.start(fn ->
        EvercamMedia.UserMailer.revoked_share_request_notification(share_request.user, share_request.camera, share_request.email)
      end)
    catch _type, error ->
      Util.error_handler(error)
    end
  end

  defp caller_has_rights(conn, user, camera) do
    cond do
      Permission.Camera.can_edit?(user, camera) -> :ok
      Permission.Camera.can_share?(user, camera) -> :ok
      true -> render_error(conn, 401, "Unauthorized.")
    end
  end

  # Delete after complete test
  defp has_caller(conn, user, camera, nil) do
    caller_has_permission(conn, user, camera)
  end
  defp has_caller(_conn, _user, _camera, _key), do: :ok

  defp caller_has_permission(conn, user, camera) do
    if Permission.Camera.can_edit?(user, camera) do
      :ok
    else
      render_error(conn, 401, "Unauthorized.")
    end
  end

  defp has_share_request(conn, email, camera, nil) do
    share_request_exists(conn, email, camera)
  end
  defp has_share_request(conn, email, camera, key) do
    case CameraShareRequest.by_key_and_email(camera, key, email) do
      nil -> render_error(conn, 404, "Share request not found.")
      %CameraShareRequest{} = camera_share_request -> {:ok, camera_share_request}
    end
  end

  defp share_request_exists(conn, email, camera) do
    case CameraShareRequest.get_pending_request(camera.id, email) do
      nil -> render_error(conn, 404, "Share request not found.")
      %CameraShareRequest{} = camera_share_request -> {:ok, camera_share_request}
    end
  end

  defp user_can_list(conn, user, camera) do
    if Permission.Camera.can_share?(user, camera), do: :ok, else: render_error(conn, 401, "Unauthorized.")
  end

  defp camera_exists(conn, camera_exid, nil), do: render_error(conn, 404, "The #{camera_exid} camera does not exist.")
  defp camera_exists(_conn, _camera_exid, _camera), do: :ok

  defp parse_status(value) when value in [nil, ""], do: nil
  defp parse_status(value) do
    value
    |> String.downcase
    |> CameraShareRequest.get_status
  end
end
