/*
Copyright (C) 2025 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

For commercial licensing, please contact support@quantumnous.com
*/

import React, { useContext, useEffect, useRef } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import {
  API,
  showError,
  showSuccess,
  updateAPI,
  setUserData,
} from '../../helpers';
import { UserContext } from '../../context/User';
import Loading from '../common/ui/Loading';

const OAuth2Callback = (props) => {
  const { t } = useTranslation();
  const [searchParams] = useSearchParams();
  const [userState, userDispatch] = useContext(UserContext);
  const navigate = useNavigate();
  
  // 防止 React 18 Strict Mode 下重复执行
  const hasExecuted = useRef(false);

  // 最大重试次数
  const MAX_RETRIES = 3;

  const clearLocalLoginState = async () => {
    if (userState?.user) {
      return;
    }
    try {
      await API.get('/api/user/logout', { skipErrorHandler: true });
    } catch (error) {}
    userDispatch({ type: 'logout' });
    localStorage.removeItem('user');
    updateAPI();
  };

  const sendCode = async (code, state, retry = 0) => {
    try {
      const { data: resData } = await API.get(
        `/api/oauth/${props.type}?code=${code}&state=${state}`,
      );

      const { success, message, data } = resData;

      if (!success) {
        await clearLocalLoginState();
        // 业务错误不重试，直接显示错误
        showError(message || t('授权失败'));
        if (userState?.user) {
          navigate('/console/personal');
        } else {
          navigate(message && message.includes('邀请码') ? '/register' : '/login');
        }
        return;
      }

      if (data?.action === 'bind') {
        showSuccess(t('绑定成功！'));
        navigate('/console/personal');
      } else {
        userDispatch({ type: 'login', payload: data });
        localStorage.setItem('user', JSON.stringify(data));
        setUserData(data);
        updateAPI();
        showSuccess(t('登录成功！'));
        navigate('/console/token');
      }
    } catch (error) {
      // 网络错误等可重试
      if (retry < MAX_RETRIES) {
        // 递增的退避等待
        await new Promise((resolve) => setTimeout(resolve, (retry + 1) * 2000));
        return sendCode(code, state, retry + 1);
      }

      // 重试次数耗尽，提示错误并返回设置页面
      await clearLocalLoginState();
      showError(error.message || t('授权失败'));
      navigate(userState?.user ? '/console/personal' : '/login');
    }
  };

  useEffect(() => {
    // 防止 React 18 Strict Mode 下重复执行
    if (hasExecuted.current) {
      return;
    }
    hasExecuted.current = true;

    const code = searchParams.get('code');
    const state = searchParams.get('state');

    // 参数缺失直接返回
    if (!code) {
      clearLocalLoginState();
      showError(t('未获取到授权码'));
      navigate(userState?.user ? '/console/personal' : '/login');
      return;
    }

    sendCode(code, state);
  }, []);

  return <Loading />;
};

export default OAuth2Callback;
