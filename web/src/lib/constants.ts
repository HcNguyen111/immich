import { env } from '$env/dynamic/public';
export const loginPageMessage: string | undefined = env.PUBLIC_LOGIN_PAGE_MESSAGE;

export enum AppRoute {
	ADMIN_USER_MANAGEMENT = '/admin/user-management',
	ADMIN_SETTINGS = '/admin/settings',
	ADMIN_STATS = '/admin/server-status',
	ADMIN_JOBS = '/admin/jobs-status',

	ALBUMS = '/albums',
	PHOTOS = '/photos',
	SHARING = '/sharing'
}
